package cloudcore

import (
	"context"
	"errors"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"github.com/gin-gonic/gin"
)

var cloudMount = regexp.MustCompile(`^/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var missingCloudFolder = errors.New("cloud folder not found")
var cloudID = regexp.MustCompile(`^[1-9][0-9]*$`)

// These routes are JNI-only. Never register them on the HTTP stream router.
func deletionRoutes(router *gin.Engine) {
	router.POST("/list115", list115)
	router.POST("/remove115", remove115)
}

type cloudTarget struct {
	Mount    string `json:"mount"`
	Path     string `json:"path"`
	ID       string `json:"id"`
	Folder   bool   `json:"folder"`
	Size     int64  `json:"size"`
	Modified int64  `json:"modified"`
}

func targetStorage(t cloudTarget, deleting bool) (driver.Driver, string, error) {
	if !cloudMount.MatchString(t.Mount) || !strings.HasPrefix(t.Path, "/") || path.Clean(t.Path) != t.Path || strings.ContainsAny(t.Path, "\x00\\") || (deleting && (t.Path == "/" || !cloudID.MatchString(t.ID))) {
		return nil, "", errors.New("invalid cloud target")
	}
	s, actual, err := op.GetStorageAndActualPath(t.Mount + t.Path)
	if err != nil || s == nil || s.GetStorage().MountPath != t.Mount || s.Config().Name != "115 Open" || s.GetStorage().Disabled || actual != t.Path {
		return nil, "", errors.New("cloud deletion unavailable")
	}
	return s, actual, nil
}

// Walk fresh objects from the root: op.Get(non-root) would reuse stale parent IDs.
func freshCloudList(ctx context.Context, s driver.Driver, p string) ([]model.Obj, error) {
	current, err := op.Get(ctx, s, "/")
	if err != nil {
		return nil, err
	}
	if p != "/" {
		for _, name := range strings.Split(strings.TrimPrefix(p, "/"), "/") {
			items, err := s.List(ctx, current, model.ListArgs{Refresh: true})
			if err != nil {
				return nil, err
			}
			current = nil
			for _, item := range items {
				if item.IsDir() && item.GetName() == name {
					if current != nil {
						return nil, errors.New("ambiguous cloud folder")
					}
					current = item
				}
			}
			if current == nil {
				return nil, missingCloudFolder
			}
		}
	}
	return s.List(ctx, current, model.ListArgs{Refresh: true})
}

type cloudSnapshot struct {
	objects []model.Obj
	expires time.Time
}

var cloudSnapshots = map[string]cloudSnapshot{} // Request serializes all JNI requests.

func list115(c *gin.Context) {
	var t struct {
		cloudTarget
		Offset  int  `json:"offset"`
		Refresh bool `json:"refresh"`
	}
	if c.ShouldBindJSON(&t) != nil || t.Offset < 0 || t.Offset%48 != 0 {
		cloudError(c)
		return
	}
	s, p, err := targetStorage(t.cloudTarget, false)
	if err != nil {
		cloudError(c)
		return
	}
	key := t.Mount + p
	snapshot, ok := cloudSnapshots[key]
	if t.Refresh || !ok || time.Now().After(snapshot.expires) {
		var items []model.Obj
		if t.Refresh {
			items, err = freshCloudList(c.Request.Context(), s, p)
		} else {
			// Ordinary browsing retains OpenList's parent cache. Only mutation
			// checks and explicit refresh walk every ancestor from the root.
			items, err = op.List(c.Request.Context(), s, p, model.ListArgs{})
		}
		if errors.Is(err, missingCloudFolder) {
			items = nil
			err = nil
		}
		if err != nil {
			delete(cloudSnapshots, key)
			cloudError(c)
			return
		}
		if len(items) > 240000 {
			cloudError(c)
			return
		}
		delete(cloudSnapshots, key)
		total := len(items)
		for _, cached := range cloudSnapshots {
			total += len(cached.objects)
		}
		for total > 240000 || len(cloudSnapshots) >= 64 {
			for cachedKey, cached := range cloudSnapshots {
				delete(cloudSnapshots, cachedKey)
				total -= len(cached.objects)
				break
			}
		}
		snapshot = cloudSnapshot{items, time.Now().Add(2 * time.Minute)}
		cloudSnapshots[key] = snapshot
	}
	if t.Offset > len(snapshot.objects) {
		cloudError(c)
		return
	}
	end := min(t.Offset+48, len(snapshot.objects))
	content := make([]gin.H, 0, end-t.Offset)
	for _, item := range snapshot.objects[t.Offset:end] {
		content = append(content, gin.H{"name": item.GetName(), "id": item.GetID(), "is_dir": item.IsDir(), "size": item.GetSize(), "modified_ms": cloudModified(item), "can_delete": cloudID.MatchString(item.GetID()) && !model.ObjHasMask(item, model.NoRemove)})
	}
	c.JSON(200, gin.H{"code": 200, "data": gin.H{"content": content, "total": len(snapshot.objects)}})
}

func cloudModified(obj model.Obj) int64 {
	if obj.ModTime().IsZero() {
		return -1
	}
	return obj.ModTime().UnixMilli()
}

func checkedCloudRemove(ctx context.Context, s driver.Driver, p string, t cloudTarget) error {
	if p == "/" || path.Clean(p) != p || !cloudID.MatchString(t.ID) {
		return errors.New("invalid cloud target")
	}
	items, err := freshCloudList(ctx, s, path.Dir(p))
	if err != nil {
		return err
	}
	var target model.Obj
	for _, item := range items {
		if item.GetName() == path.Base(p) {
			if target != nil {
				return errors.New("ambiguous cloud file")
			}
			target = item
		}
	}
	if target == nil || target.GetID() != t.ID || target.IsDir() != t.Folder || model.ObjHasMask(target, model.NoRemove) || (!t.Folder && (target.GetSize() != t.Size || (t.Modified >= 0 && cloudModified(target) != t.Modified))) {
		return errors.New("cloud file changed")
	}
	remover, ok := s.(driver.Remove)
	if !ok {
		return errors.New("cloud deletion unavailable")
	}
	// One ordinary deletion of the verified object. No child-by-child removal,
	// recycle-bin purge, or replay after an ambiguous transport error.
	return remover.Remove(ctx, target)
}

func remove115(c *gin.Context) {
	var t cloudTarget
	if c.ShouldBindJSON(&t) != nil {
		cloudError(c)
		return
	}
	s, p, err := targetStorage(t, true)
	if err != nil {
		cloudError(c)
		return
	}
	err = checkedCloudRemove(c.Request.Context(), s, p, t)
	for key := range cloudSnapshots {
		if strings.HasPrefix(key, t.Mount+"/") {
			delete(cloudSnapshots, key)
		}
	}
	op.Cache.DeleteDirectoryTree(s, "/")
	if err != nil {
		cloudError(c)
		return
	}
	c.JSON(200, gin.H{"code": 200, "data": nil})
}

func cloudError(c *gin.Context) { c.JSON(200, gin.H{"code": 500, "message": "Cloud request failed"}) }

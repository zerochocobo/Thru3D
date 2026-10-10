package cloudcore

import (
	"context"
	"errors"
	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"testing"
	"time"
)

type deletionFixture struct {
	model.Storage
	files   map[string][]model.Obj
	reads   []string
	writes  []string
	failure bool
}

func (d *deletionFixture) Config() driver.Config          { return driver.Config{Name: "115 Open"} }
func (d *deletionFixture) GetAddition() driver.Additional { return nil }
func (d *deletionFixture) Init(context.Context) error     { return nil }
func (d *deletionFixture) Drop(context.Context) error     { return nil }
func (d *deletionFixture) GetRoot(context.Context) (model.Obj, error) {
	return &model.Object{ID: "0", Name: "root", IsFolder: true}, nil
}
func (d *deletionFixture) List(_ context.Context, dir model.Obj, _ model.ListArgs) ([]model.Obj, error) {
	d.reads = append(d.reads, dir.GetID())
	return d.files[dir.GetID()], nil
}
func (d *deletionFixture) Link(context.Context, model.Obj, model.LinkArgs) (*model.Link, error) {
	panic("Deletion must not download")
}
func (d *deletionFixture) Remove(_ context.Context, obj model.Obj) error {
	d.writes = append(d.writes, obj.GetID())
	if d.failure {
		return errors.New("ambiguous transport failure")
	}
	return nil
}
func testObj(id, name string, folder bool) model.Obj {
	return &model.Object{ID: id, Name: name, IsFolder: folder, Size: 12, Modified: time.UnixMilli(10)}
}
func TestFreshDeletionWalksCurrentAncestorsAndRemovesOneID(t *testing.T) {
	d := &deletionFixture{files: map[string][]model.Obj{
		"0": {testObj("2", "旅行", true)}, "2": {testObj("3", "中文 #%.mp4", false)},
	}}
	target := cloudTarget{ID: "3", Size: 12, Modified: 10}
	if err := checkedCloudRemove(context.Background(), d, "/旅行/中文 #%.mp4", target); err != nil {
		t.Fatal(err)
	}
	if len(d.writes) != 1 || d.writes[0] != "3" || len(d.reads) != 2 || d.reads[0] != "0" || d.reads[1] != "2" {
		t.Fatal(d.writes, d.reads)
	}
}
func TestDeletionRejectsReplacementLockedMetadataAndRoot(t *testing.T) {
	for _, tc := range []struct {
		name, path string
		obj        model.Obj
		target     cloudTarget
	}{
		{"replaced", "/a.mp4", testObj("2", "a.mp4", false), cloudTarget{ID: "1", Size: 12, Modified: 10}},
		{"changed size", "/a.mp4", testObj("1", "a.mp4", false), cloudTarget{ID: "1", Size: 13, Modified: 10}},
		{"changed time", "/a.mp4", testObj("1", "a.mp4", false), cloudTarget{ID: "1", Size: 12, Modified: 11}},
		{"wrong kind", "/a.mp4", testObj("1", "a.mp4", false), cloudTarget{ID: "1", Folder: true}},
		{"root", "/", testObj("1", "a.mp4", false), cloudTarget{ID: "1"}},
		{"forged id", "/a.mp4", testObj("1", "a.mp4", false), cloudTarget{ID: "1,2"}},
		{"locked", "/a.mp4", &model.Object{ID: "1", Name: "a.mp4", Mask: model.NoRemove}, cloudTarget{ID: "1"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := &deletionFixture{files: map[string][]model.Obj{"0": {tc.obj}}}
			if checkedCloudRemove(context.Background(), d, tc.path, tc.target) == nil || len(d.writes) != 0 {
				t.Fatal("Guard failed", d.writes)
			}
		})
	}
}
func TestDeletionOfFolderUsesOneDriverCallAndNeverRetries(t *testing.T) {
	d := &deletionFixture{files: map[string][]model.Obj{"0": {testObj("9", "folder", true)}}, failure: true}
	if checkedCloudRemove(context.Background(), d, "/folder", cloudTarget{ID: "9", Folder: true}) == nil {
		t.Fatal("Expected transport error")
	}
	if len(d.writes) != 1 || d.writes[0] != "9" {
		t.Fatal("Unexpected repeated deletion", d.writes)
	}
}
func TestTargetStorageRejectsTraversalRootAndForeignMountBeforeWrite(t *testing.T) {
	for _, p := range []string{"/", "/../a", "/a/../b", "//a", "/a/", "/a\x00", "/a\\b"} {
		if _, _, err := targetStorage(cloudTarget{Mount: "/12345678-1234-1234-1234-123456789abc", Path: p, ID: "1"}, true); err == nil {
			t.Fatal("Accepted", p)
		}
	}
	if _, _, err := targetStorage(cloudTarget{Mount: "/fixture", Path: "/a.mp4", ID: "1"}, true); err == nil {
		t.Fatal("Accepted foreign mount")
	}
}

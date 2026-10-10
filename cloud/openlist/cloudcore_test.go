package cloudcore

import (
	"bytes"
	"encoding/json"
	"github.com/OpenListTeam/OpenList/v4/internal/db"
	"io"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"golang.org/x/net/webdav"
)

// Exercise the real OpenList WebDAV driver and real stream router, including
// credentials/Range forwarding. No personal cloud account is needed.
func TestBrowseAndRangeStream(t *testing.T) {
	dir := t.TempDir()
	name := "中文 #%.mp4"
	payload := bytes.Repeat([]byte("0123456789abcdef"), 1024)
	if err := os.WriteFile(filepath.Join(dir, name), payload, 0600); err != nil {
		t.Fatal(err)
	}
	var reads atomic.Int32
	dav := &webdav.Handler{FileSystem: webdav.Dir(dir), LockSystem: webdav.NewMemLS()}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u, p, ok := r.BasicAuth()
		if !ok || u != "fixture" || p != "private-secret" {
			w.Header().Set("WWW-Authenticate", `Basic realm="test"`)
			w.WriteHeader(401)
			return
		}
		if r.Method == "GET" {
			reads.Add(1)
		}
		dav.ServeHTTP(w, r)
	}))
	defer upstream.Close()
	if err := Start(t.TempDir(), strings.Repeat("ab", 32)); err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	call := func(method, route string, body any) map[string]any {
		b, _ := json.Marshal(body)
		raw, err := Request(method, route, string(b))
		if err != nil {
			t.Fatal(err)
		}
		var out map[string]any
		if err = json.Unmarshal([]byte(raw), &out); err != nil {
			t.Fatal(err)
		}
		if out["code"] != float64(200) {
			t.Fatalf("%s failed: %s", route, raw)
		}
		return out
	}
	addition, _ := json.Marshal(map[string]any{"address": upstream.URL, "username": "fixture", "password": "private-secret", "root_folder_path": "/", "vendor": "other"})
	created := call("POST", "/create", map[string]any{"mount_path": "/fixture", "driver": "WebDav", "addition": string(addition), "web_proxy": true, "cache_expiration": 5})
	id := int(created["data"].(map[string]any)["id"].(float64))
	var stored string
	if err := db.GetDb().Raw("SELECT addition FROM x_storages WHERE id = ?", id).Scan(&stored).Error; err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(stored, "vrpp1:") || strings.Contains(stored, "private-secret") {
		t.Fatal("credentials are not encrypted")
	}
	// Read through GORM again: serialization must restore tokens for restarts.
	loaded, err := db.GetStorageById(uint(id))
	if err != nil || !strings.Contains(loaded.Addition, "private-secret") {
		t.Fatal("stored account did not decrypt", err)
	}
	defer func() { Request("POST", "/delete?id="+fmtInt(id), "") }()
	listed := call("POST", "/list", map[string]any{"path": "/fixture", "page": 1, "per_page": 500})
	items := listed["data"].(map[string]any)["content"].([]any)
	if len(items) != 1 || items[0].(map[string]any)["name"] != name {
		t.Fatal("file metadata changed")
	}
	if reads.Load() != 0 {
		t.Fatal("browsing read the video body")
	}
	paged := filepath.Join(dir, "paged")
	if err := os.Mkdir(paged, 0700); err != nil { t.Fatal(err) }
	for i := 0; i < 55; i++ {
		if err := os.WriteFile(filepath.Join(paged, fmt.Sprintf("%03d.txt", i)), []byte("metadata fixture"), 0600); err != nil { t.Fatal(err) }
	}
	call("POST", "/list", map[string]any{"path":"/fixture","page":1,"per_page":48,"refresh":true})
	first := call("POST", "/list", map[string]any{"path":"/fixture/paged","page":1,"per_page":48})["data"].(map[string]any)
	second := call("POST", "/list", map[string]any{"path":"/fixture/paged","page":2,"per_page":48})["data"].(map[string]any)
	if first["total"]!=float64(55) || len(first["content"].([]any))!=48 || len(second["content"].([]any))!=7 { t.Fatal("core UI pagination failed") }
	if reads.Load()!=0 { t.Fatal("paginated metadata browsing read a file body") }
	link, err := Stream("/fixture/" + name)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		method, span string
		code         int
		want         []byte
	}{
		{"HEAD", "", 200, nil}, {"GET", "bytes=42-103", 206, payload[42:104]},
		{"GET", "bytes=-16", 206, payload[len(payload)-16:]},
	} {
		req, _ := http.NewRequest(tc.method, link, nil)
		if tc.span != "" {
			req.Header.Set("Range", tc.span)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != tc.code || !bytes.Equal(body, tc.want) {
			t.Fatalf("%s %s: status=%d bytes=%d", tc.method, tc.span, res.StatusCode, len(body))
		}
	}

	// File management is not reachable through the loopback media listener.
	base := streamBase[:strings.LastIndex(streamBase, "/")]
	for _, route := range []string{"/remove115", "/list115"} {
		response, err := http.Post(base+route, "application/json", strings.NewReader("{}"))
		if err != nil { t.Fatal(err) }; response.Body.Close()
		if response.StatusCode != 404 { t.Fatal("management route exposed", route) }
	}
	mount := "/12345678-1234-1234-1234-123456789abc"
	foreign := call("POST", "/create", map[string]any{"mount_path":mount,"driver":"WebDav","addition":string(addition),"web_proxy":true})
	foreignID := int(foreign["data"].(map[string]any)["id"].(float64))
	defer func() { Request("POST","/delete?id="+fmtInt(foreignID),"") }()
	body, _ := json.Marshal(map[string]any{"mount":mount,"path":"/"+name,"id":"9","size":len(payload)})
	refused, err := Request("POST","/remove115",string(body))
	if err != nil { t.Fatal(err) }
	var result map[string]any
	if json.Unmarshal([]byte(refused),&result)!=nil || result["code"]==float64(200) { t.Fatal("non-115 mount accepted") }
	if _, err:=os.Stat(filepath.Join(dir,name)); err!=nil { t.Fatal("foreign file changed",err) }
	for _, route := range []string{"/api/admin/storage/list", "/dav/fixture/", "/wrong/fixture/video.mp4"} {
		res, err := http.Get(base + route)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode != 404 {
			t.Fatal("unexpected public route", route, res.StatusCode)
		}
	}
	assertBaiduCore(t,call)
	assertAliyunCore(t,call)
}

func fmtInt(value int) string { b, _ := json.Marshal(value); return string(b) }

func TestCoreRestartProbe(t *testing.T) {
	mode := os.Getenv("VRPP_CORE_RESTART_MODE")
	if mode == "" { t.Skip("child process only") }
	if err := Start(os.Getenv("VRPP_CORE_RESTART_DATA"), strings.Repeat("ab", 32)); err != nil { t.Fatal(err) }
	defer db.Close()
	call := func(method, route string, body any) map[string]any {
		b, _ := json.Marshal(body)
		raw, err := Request(method, route, string(b))
		if err != nil { t.Fatal("core request failed") }
		var out map[string]any
		if json.Unmarshal([]byte(raw), &out) != nil || out["code"] != float64(200) { t.Fatalf("fixture core response failed: route=%s code=%v message=%v", route, out["code"], out["message"]) }
		return out
	}
	if mode == "write" {
		addition := map[string]any{"address":os.Getenv("VRPP_CORE_RESTART_URL"),"username":"fixture","password":"private-secret","root_folder_path":"/","vendor":"other"}
		a, _ := json.Marshal(addition)
		storage := map[string]any{"mount_path":"/restart","driver":"WebDav","addition":string(a),"web_proxy":true,"cache_expiration":5}
		created := call("POST","/create",storage)
		id := int(created["data"].(map[string]any)["id"].(float64))
		// The same UpdateStorage/serializer path persists driver token rotation.
		addition["password"] = "private-rotated"
		a, _ = json.Marshal(addition)
		storage["id"], storage["addition"] = id, string(a)
		call("POST","/update",storage)
		var sealed string
		if db.GetDb().Raw("SELECT addition FROM x_storages WHERE id = ?", id).Scan(&sealed).Error != nil ||
			!strings.HasPrefix(sealed,"vrpp1:") || strings.Contains(sealed,"private-rotated") { t.Fatal("updated credentials not encrypted") }
		return
	}
	data := call("POST","/list",map[string]any{"path":"/restart","page":1,"per_page":48})
	files := data["data"].(map[string]any)["content"].([]any)
	if len(files)!=1 || files[0].(map[string]any)["name"]!="restart.mp4" { t.Fatal("mount did not survive process restart") }
	link, err := Stream("/restart/restart.mp4")
	if err != nil { t.Fatal(err) }
	request, _ := http.NewRequest("GET", link, nil)
	request.Header.Set("Range","bytes=4-7")
	response, err := http.DefaultClient.Do(request)
	if err != nil { t.Fatal(err) }
	defer response.Body.Close()
	bytes, _ := io.ReadAll(response.Body)
	if response.StatusCode != 206 || string(bytes)!="4567" { t.Fatal("restored original-file range failed") }
}

func TestEncryptedMountSurvivesFreshProcessAndCredentialRotation(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir,"restart.mp4"), []byte("0123456789"),0600); err != nil { t.Fatal(err) }
	var rotated atomic.Bool
	dav := &webdav.Handler{FileSystem:webdav.Dir(dir),LockSystem:webdav.NewMemLS()}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request) {
		user, password, _ := r.BasicAuth()
		valid := password=="private-rotated" || (!rotated.Load() && password=="private-secret")
		if user!="fixture" || !valid { w.Header().Set("WWW-Authenticate", `Basic realm="fixture"`); w.WriteHeader(401); return }
		dav.ServeHTTP(w,r)
	}))
	defer upstream.Close()
	data := t.TempDir()
	for _, mode := range []string{"write","read"} {
		if mode=="read" { rotated.Store(true) }
		command := exec.Command(os.Args[0],"-test.run=^TestCoreRestartProbe$","-test.v")
		command.Env = append(os.Environ(),"VRPP_CORE_RESTART_MODE="+mode,"VRPP_CORE_RESTART_DATA="+data,"VRPP_CORE_RESTART_URL="+upstream.URL)
		if output, err := command.CombinedOutput(); err != nil { t.Fatalf("restart %s failed: %v\n%s",mode,err,output) }
	}
}

// Optional read-only probe of the user-supplied remote server, isolated from normal fixtures.
func TestLiveRemoteWebDav(t *testing.T) {
    address := os.Getenv("VRPP_REMOTE_DAV_URL")
    if address == "" { t.Skip("remote WebDAV test not configured") }
    secret := os.Getenv("VRPP_REMOTE_DAV_PASSWORD")
    if err := Start(t.TempDir(), strings.Repeat("ab", 32)); err != nil { t.Fatal("core start failed") }
    defer db.Close()
    call := func(method, route string, body any) map[string]any {
        encoded, _ := json.Marshal(body)
        raw, err := Request(method, route, string(encoded))
        if err != nil { t.Fatalf("remote WebDAV request failed: %s", route) }
        var result map[string]any
        if json.Unmarshal([]byte(raw), &result) != nil || result["code"] != float64(200) {
            message, _ := result["message"].(string)
            if secret != "" { message = strings.ReplaceAll(message, secret, "[redacted]") }
            if user := os.Getenv("VRPP_REMOTE_DAV_USER"); user != "" { message = strings.ReplaceAll(message, user, "[redacted]") }
            t.Fatalf("remote WebDAV operation failed: %s: %s", route, message)
        }
        return result
    }
    addition, _ := json.Marshal(map[string]any{"address":address,"username":os.Getenv("VRPP_REMOTE_DAV_USER"),
        "password":secret,"vendor":"other","root_folder_path":"/","tls_insecure_skip_verify":false})
    created := call("POST", "/create", map[string]any{"mount_path":"/remote-dav-probe", "driver":"WebDav",
        "addition":string(addition),"web_proxy":true,"cache_expiration":5})
    id := int(created["data"].(map[string]any)["id"].(float64))
    defer func() { Request("POST", "/delete?id="+fmtInt(id), "") }()
    var stored string
    if db.GetDb().Raw("SELECT addition FROM x_storages WHERE id = ?", id).Scan(&stored).Error != nil ||
        !strings.HasPrefix(stored,"vrpp1:") || (secret != "" && strings.Contains(stored, secret)) {
        t.Fatal("remote WebDAV credentials were not encrypted")
    }
    profile := call("GET", "/account?id="+fmtInt(id), nil)["data"].(map[string]any)
    if profile["driver"] != "WebDav" || profile["mount_path"] != "/remote-dav-probe" { t.Fatal("profile identity changed") }
    var decoded map[string]any
    if json.Unmarshal([]byte(profile["addition"].(string)), &decoded) != nil || decoded["address"] != address ||
        decoded["username"] != os.Getenv("VRPP_REMOTE_DAV_USER") || decoded["password"] != secret {
        t.Fatal("remote WebDAV connection configuration roundtrip changed")
    }
    type directory struct { path string; depth int }
    queue := []directory{{"/remote-dav-probe",0}}
    visited := 0
    var media string
    var mediaSize int64
    for len(queue)>0 && visited<24 && media=="" {
        folder := queue[0]; queue=queue[1:]; visited++
        result := call("POST", "/list", map[string]any{"path":folder.path,"page":1,"per_page":48,"refresh":false})
        data := result["data"].(map[string]any)
        entries, _ := data["content"].([]any)
        if entries == nil && data["total"] != float64(0) { t.Fatal("invalid directory response") }
        if visited==1 { t.Logf("authenticated root entries=%d",len(entries)) }
        for _, item := range entries {
            file := item.(map[string]any); name := file["name"].(string)
            if name=="." || name==".." || strings.ContainsAny(name,"/\x00") { continue }
            child := strings.TrimRight(folder.path,"/")+"/"+name
            if file["is_dir"].(bool) {
                if folder.depth<3 { queue=append(queue,directory{child,folder.depth+1}) }
            } else {
                lower := strings.ToLower(name)
                for _, ext := range []string{".mp4",".mkv",".webm",".mov"} {
                    if strings.HasSuffix(lower,ext) && file["size"].(float64)>128 {
                        media=child; mediaSize=int64(file["size"].(float64)); break
                    }
                }
            }
            if media!="" { break }
        }
    }
    if media=="" { t.Logf("directories validated=%d; no media found in bounded probe",visited); return }
    stream,err := Stream(media)
    if err!=nil { t.Fatal("remote media stream creation failed") }
    for _, offset := range []int64{0,mediaSize/2} {
        req,_ := http.NewRequest("GET",stream,nil)
        req.Header.Set("Range",fmt.Sprintf("bytes=%d-%d",offset,offset+31))
        client := &http.Client{Timeout:30*1000000000}
        response,err := client.Do(req)
        if err!=nil { t.Fatal("remote media read failed") }
        data,err := io.ReadAll(io.LimitReader(response.Body,33)); response.Body.Close()
        if err!=nil || response.StatusCode!=206 || len(data)!=32 { t.Fatal("remote media Range read failed") }
    }
    t.Log("real remote WebDAV directory, encrypted profile and two media byte ranges passed")
}

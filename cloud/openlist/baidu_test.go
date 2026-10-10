package cloudcore

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/db"
)

type baiduTransport func(*http.Request) (*http.Response, error)

func (f baiduTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// Exercise the pinned Baidu driver and real JNI/stream adapters without accounts
// or upstream network. No request may escape this fixture.
func assertBaiduCore(t *testing.T, call func(string, string, any) map[string]any) {
	t.Helper()
	payload := bytes.Repeat([]byte("baidu-original-fixture"), 2048)
	var reads atomic.Int32
	var rotated atomic.Bool
	media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("User-Agent") != "pan.baidu.com" {
			t.Error("Baidu download header lost")
		}
		if r.Method == "GET" {
			reads.Add(1)
		}
		http.ServeContent(w, r, "video.mp4", time.Unix(0, 0), bytes.NewReader(payload))
	}))
	defer media.Close()
	original, originalHead := base.RestyClient.GetClient().Transport, base.NoRedirectClient.GetClient().Transport
	fixture := baiduTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host == "baidu-fixture.invalid" && r.Method == "HEAD" {
			if r.Header.Get("User-Agent") != "pan.baidu.com" {
				t.Error("Baidu link header lost")
			}
			return &http.Response{StatusCode: 302, Header: http.Header{"Location": []string{media.URL + "/original.mp4"}}, Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
		}
		if r.URL.Host == "api.oplist.org" && r.URL.Path == "/baiduyun/renewapi" && r.Method == "GET" {
			q := r.URL.Query()
			if q.Get("refresh_ui") != "refresh-fixture" || q.Get("server_use") != "true" || q.Get("driver_txt") != "baiduyun_go" {
				t.Error("Wrong Baidu public renewal parameters")
			}
			return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(`{"access_token":"access-fixture-rotated","refresh_token":"refresh-fixture-rotated"}`)), Request: r}, nil
		}
		if r.URL.Host != "pan.baidu.com" || r.Method != "GET" {
			return nil, fmt.Errorf("unexpected fixture request: %s %s", r.Method, r.URL.Host)
		}
		if r.URL.Query().Get("access_token") != "access-fixture" && r.URL.Query().Get("access_token") != "access-fixture-rotated" {
			t.Error("Initial OAuth access token not used")
		}
		var body string
		switch {
		case r.URL.Path == "/rest/2.0/xpan/nas":
			body = `{"errno":0,"vip_type":0}`
		case r.URL.Query().Get("method") == "filemetas":
			body = `{"errno":0,"list":[{"dlink":"https://baidu-fixture.invalid/redirect"}]}`
		case r.URL.Query().Get("method") == "list":
			if r.URL.Query().Get("dir") == "/" && !rotated.Swap(true) {
				body = `{"errno":111}`
			} else if r.URL.Query().Get("dir") == "/" {
				body = `{"errno":0,"list":[{"fs_id":9007199254740993,"server_filename":"旅行","path":"/旅行","isdir":1}]}`
			} else if r.URL.Query().Get("dir") == "/旅行" {
				body = fmt.Sprintf(`{"errno":0,"list":[{"fs_id":9007199254740994,"server_filename":"中文 #%%.mp4","path":"/旅行/中文 #%%.mp4","isdir":0,"size":%d,"server_mtime":123}]}`, len(payload))
			} else {
				return nil, fmt.Errorf("unexpected directory")
			}
		default:
			return nil, fmt.Errorf("unexpected Baidu method")
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
	})
	base.RestyClient.SetTransport(fixture)
	base.NoRedirectClient.SetTransport(fixture)
	defer func() { base.RestyClient.SetTransport(original); base.NoRedirectClient.SetTransport(originalHead) }()
	addition, _ := json.Marshal(map[string]any{"root_folder_path": "/", "AccessToken": "access-fixture", "refresh_token": "refresh-fixture", "use_online_api": true, "api_url_address": "https://api.oplist.org/baiduyun/renewapi", "download_api": "official"})
	mount := "/baidu-fixture"
	created := call("POST", "/create", map[string]any{"mount_path": mount, "driver": "BaiduNetdisk", "addition": string(addition), "cache_expiration": 5, "web_proxy": true})
	id := int(created["data"].(map[string]any)["id"].(float64))
	defer func() { Request("POST", "/delete?id="+fmtInt(id), "") }()
	folder := call("POST", "/list", map[string]any{"path": mount, "page": 1, "per_page": 48})["data"].(map[string]any)["content"].([]any)
	if len(folder) != 1 || folder[0].(map[string]any)["name"] != "旅行" {
		t.Fatal("Baidu root metadata changed")
	}
	var stored string
	if err := db.GetDb().Raw("SELECT addition FROM x_storages WHERE id = ?", id).Scan(&stored).Error; err != nil {
		t.Fatal(err)
	}
	loaded, err := db.GetStorageById(uint(id))
	if err != nil || !strings.HasPrefix(stored, "vrpp1:") || strings.Contains(stored, "refresh-fixture") || !strings.Contains(loaded.Addition, "refresh-fixture-rotated") {
		t.Fatal("Baidu rotated credential storage failed", err)
	}
	files := call("POST", "/list", map[string]any{"path": mount + "/旅行", "page": 1, "per_page": 48})["data"].(map[string]any)["content"].([]any)
	if len(files) != 1 || files[0].(map[string]any)["name"] != "中文 #%.mp4" || reads.Load() != 0 {
		t.Fatal("Baidu browse downloaded media or changed metadata")
	}
	link, err := Stream(mount + "/旅行/中文 #%.mp4")
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest("GET", link, nil)
	req.Header.Set("Range", "bytes=4-23")
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != 206 || !bytes.Equal(body, payload[4:24]) {
		t.Fatal("Baidu original-file seek failed", response.StatusCode, len(body))
	}
}

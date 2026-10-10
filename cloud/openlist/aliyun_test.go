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

// Real pinned AliyundriveOpen driver; every external API request is intercepted.
// This is not a real-account authorization or hardware playback test.
func assertAliyunCore(t *testing.T, call func(string,string,any) map[string]any) {
    t.Helper()
    payload := bytes.Repeat([]byte("aliyun-original-fixture"),2048)
    media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request) {
        http.ServeContent(w,r,"clip.mp4",time.Unix(0,0),bytes.NewReader(payload))
    }))
    defer media.Close()
    original := base.RestyClient.GetClient().Transport
    var rotated atomic.Bool
    base.RestyClient.SetTransport(baiduTransport(func(r *http.Request) (*http.Response,error) {
        status:=200
        var response string
        if r.URL.Host=="api.oplist.org" && r.URL.Path=="/alicloud/renewapi" && r.Method=="GET" {
            q:=r.URL.Query()
            if q.Get("server_use")!="true" || q.Get("refresh_ui")!="ali-refresh-fixture" || q.Get("driver_txt")!="alicloud_qr" {
                t.Error("Aliyun shared renewal parameters changed")
            }
            rotated.Store(true)
            response=`{"access_token":"ali-access-rotated","refresh_token":"ali-refresh-rotated"}`
        } else {
            if r.URL.Host!="openapi.alipan.com" || r.Method!="POST" {
                return nil,fmt.Errorf("external request escaped Aliyun fixture")
            }
            if !rotated.Load() {
                status=401; response=`{"code":"AccessTokenExpired","message":"fixture"}`
            } else {
                if r.Header.Get("Authorization")!="Bearer ali-access-rotated" { t.Error("refreshed token not used") }
                body,_:=io.ReadAll(r.Body)
                var params map[string]any
                json.Unmarshal(body,&params)
                switch r.URL.Path {
                case "/adrive/v1.0/user/getDriveInfo":
                    response=`{"user_id":"ali-fixture-user","default_drive_id":"drive-fixture"}`
                case "/adrive/v1.0/openFile/list":
                    if params["drive_id"]!="drive-fixture" { t.Error("wrong drive ID") }
                    if params["parent_file_id"]=="root" {
                        response=`{"items":[{"file_id":"folder-fixture","name":"directory","type":"folder","updated_at":"2026-10-09T00:00:00Z"}]}`
                    } else if params["parent_file_id"]=="folder-fixture" {
                        response=fmt.Sprintf(`{"items":[{"file_id":"video-fixture","name":"clip #%%.mp4","type":"file","size":%d,"updated_at":"2026-10-09T00:00:00Z"}]}`,len(payload))
                    } else { return nil,fmt.Errorf("unexpected folder") }
                case "/adrive/v1.0/openFile/getDownloadUrl":
                    if params["file_id"]!="video-fixture" { t.Error("wrong download object") }
                    response=fmt.Sprintf(`{"url":%q}`,media.URL+"/clip.mp4")
                default: return nil,fmt.Errorf("unexpected Aliyun API")
                }
            }
        }
        return &http.Response{StatusCode:status,Header:http.Header{"Content-Type":[]string{"application/json"}},Body:io.NopCloser(strings.NewReader(response)),Request:r},nil
    }))
    defer base.RestyClient.SetTransport(original)
    addition,_:=json.Marshal(map[string]any{"root_folder_id":"root","drive_type":"default","AccessToken":"ali-access-fixture",
        "refresh_token":"ali-refresh-fixture","use_online_api":true,"alipan_type":"default",
        "api_url_address":"https://api.oplist.org/alicloud/renewapi","client_id":"","client_secret":"","order_by":"name","order_direction":"ASC"})
    mount:="/aliyun-fixture"
    created:=call("POST","/create",map[string]any{"mount_path":mount,"driver":"AliyundriveOpen","addition":string(addition),"web_proxy":true,"cache_expiration":5})
    id:=int(created["data"].(map[string]any)["id"].(float64))
    defer Request("POST","/delete?id="+fmtInt(id),"")
    root:=call("POST","/list",map[string]any{"path":mount,"page":1,"per_page":48})["data"].(map[string]any)
    if root["total"]!=float64(1) { t.Fatal("Aliyun root directory failed") }
    files:=call("POST","/list",map[string]any{"path":mount+"/directory","page":1,"per_page":48})["data"].(map[string]any)
    if files["total"]!=float64(1) { t.Fatal("Aliyun nested directory failed") }
    var stored string
    if db.GetDb().Raw("SELECT addition FROM x_storages WHERE id = ?",id).Scan(&stored).Error!=nil ||
        !strings.HasPrefix(stored,"vrpp1:") || strings.Contains(stored,"ali-refresh") || strings.Contains(stored,"ali-access") { t.Fatal("Aliyun refreshed credentials not encrypted") }
    decoded:=call("GET","/account?id="+fmtInt(id),nil)["data"].(map[string]any)["addition"].(string)
    if !strings.Contains(decoded,"ali-refresh-rotated") { t.Fatal("Aliyun refresh not persisted") }
    stream,err:=Stream(mount+"/directory/clip #%.mp4")
    if err!=nil { t.Fatal(err) }
    for _,offset:=range []int{0,len(payload)/2} {
        request,_:=http.NewRequest("GET",stream,nil)
        request.Header.Set("Range",fmt.Sprintf("bytes=%d-%d",offset,offset+31))
        response,err:=http.DefaultClient.Do(request)
        if err!=nil { t.Fatal(err) }
        data,err:=io.ReadAll(response.Body);response.Body.Close()
        if err!=nil || response.StatusCode!=206 || !bytes.Equal(data,payload[offset:offset+32]) { t.Fatal("Aliyun original-file range mismatch") }
    }
}

// Package cloudcore is the player's in-process OpenList adapter. It is built
// inside the pinned upstream module because OpenList's API is internal.
package cloudcore

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/OpenListTeam/OpenList/v4/cmd/flags"
	_ "github.com/OpenListTeam/OpenList/v4/drivers/115_open"
	_ "github.com/OpenListTeam/OpenList/v4/drivers/baidu_netdisk"
	_ "github.com/OpenListTeam/OpenList/v4/drivers/onedrive"
	_ "github.com/OpenListTeam/OpenList/v4/drivers/aliyundrive_open"
	_ "github.com/OpenListTeam/OpenList/v4/drivers/quark_open"
	_ "github.com/OpenListTeam/OpenList/v4/drivers/webdav"
	"github.com/OpenListTeam/OpenList/v4/internal/bootstrap"
	"github.com/OpenListTeam/OpenList/v4/internal/bootstrap/data"
	"github.com/OpenListTeam/OpenList/v4/internal/conf"
	"github.com/OpenListTeam/OpenList/v4/internal/db"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/pkg/utils"
	"github.com/OpenListTeam/OpenList/v4/server/common"
	"github.com/OpenListTeam/OpenList/v4/server/handles"
	"github.com/OpenListTeam/OpenList/v4/server/middlewares"
	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"
	"gorm.io/gorm"
	"gorm.io/gorm/schema"
)

var once sync.Once
var startErr error
var api *gin.Engine
var streamBase string
var admin *model.User
var requestMu sync.Mutex

// Start is lazy and process-scoped. Android owns the database in noBackupFilesDir.
// No admin HTTP server, WebDAV listener, guest API or discovery service is opened.
func Start(dataDir, keyHex string) error {
	once.Do(func() { startErr = start(dataDir, keyHex) })
	return startErr
}

func start(dataDir, keyHex string) (err error) {
	defer func() {
		if recover() != nil {
			err = errors.New("cloud initialization failed")
		}
	}()
	if !filepath.IsAbs(dataDir) {
		return errors.New("absolute data directory required")
	}
	key, err := hex.DecodeString(keyHex)
	if err != nil || len(key) != 32 {
		return errors.New("invalid cloud key")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return err
	}
	schema.RegisterSerializer("vrpp_secret", secretField{aead})
	if err = os.MkdirAll(dataDir, 0700); err != nil {
		return errors.New("cloud storage unavailable")
	}
	log.SetOutput(io.Discard)
	utils.Log.SetOutput(io.Discard)
	// Upstream command bootstrap uses Fatal. A library must not exit the player.
	log.StandardLogger().ExitFunc = func(int) { panic("bootstrap failed") }
	utils.Log.ExitFunc = log.StandardLogger().ExitFunc
	gin.SetMode(gin.ReleaseMode)
	gin.DefaultWriter, gin.DefaultErrorWriter = io.Discard, io.Discard
	flags.DataDir = dataDir
	cfg := conf.DefaultConfig(dataDir)
	cfg.Force = true
	cfg.Log.Enable = false
	cfg.Scheme.Address, cfg.Scheme.HttpPort = "127.0.0.1", -1
	cfg.AutoMemoryLimit, cfg.MaxConcurrency = 0, 8
	cfg.MaxBlockLimit, cfg.MinFreeMemory = 4, -1
	b, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(dataDir, "config.json"), b, 0600); err != nil {
		return err
	}
	bootstrap.InitConfig()
	bootstrap.Log()
	bootstrap.InitDB()
	// Pre-create the private admin to avoid the command bootstrap printing an
	// initial password to stdout/logcat. No login endpoint is exposed.
	admin, err = db.GetUserByRole(model.ADMIN)
	if errors.Is(err, gorm.ErrRecordNotFound) {
		password := make([]byte, 32)
		if _, err = rand.Read(password); err != nil {
			return err
		}
		admin = (&model.User{Username: "player", Role: model.ADMIN, BasePath: "/", Authn: "[]"}).SetPassword(hex.EncodeToString(password))
		err = db.CreateUser(admin)
	}
	if err != nil {
		return errors.New("cloud user unavailable")
	}
	data.InitData()
	bootstrap.InitStreamLimit()
	bootstrap.InitIndex()
	bootstrap.InitUpgradePatch()
	common.SecretKey = []byte(conf.Conf.JwtSecret)
	bootstrap.LoadStorages()
	api = gin.New()
	api.Use(gin.Recovery(), middlewares.StoragesLoaded, middlewares.Auth(false), middlewares.AuthAdmin)
	api.POST("/list", handles.FsListSplit)
	deletionRoutes(api)
	api.GET("/drivers", handles.ListDriverInfo)
	api.GET("/accounts", handles.ListStorages)
	api.GET("/account", handles.GetStorage)
	api.POST("/create", handles.CreateStorage)
	api.POST("/update", handles.UpdateStorage)
	api.POST("/delete", handles.DeleteStorage)
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return errors.New("cloud stream unavailable")
	}
	capabilityKey := make([]byte, 32)
	if _, err = rand.Read(capabilityKey); err != nil {
		listener.Close()
		return err
	}
	capability := hex.EncodeToString(capabilityKey)
	streams := gin.New()
	streams.Use(gin.Recovery(), middlewares.StoragesLoaded)
	// The unguessable per-process path authorizes this loopback-only stream.
	chain := []gin.HandlerFunc{middlewares.PathParse, middlewares.Down(func(string, string) error { return nil }), handles.Proxy}
	streams.GET("/"+capability+"/*path", chain...)
	streams.HEAD("/"+capability+"/*path", chain...)
	server := &http.Server{Handler: streams, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second}
	streamBase = "http://" + listener.Addr().String() + "/" + capability
	go server.Serve(listener)
	return nil
}

// The build applies this serializer only to Storage.Addition, where drivers
// persist cookies and refreshed tokens. Live driver objects remain plaintext;
// SQLite, its WAL and backups never receive those credentials in plaintext.
type secretField struct{ aead cipher.AEAD }

func (s secretField) Value(_ context.Context, _ *schema.Field, _ reflect.Value, value any) (any, error) {
	plain, ok := value.(string)
	if !ok {
		return nil, errors.New("invalid cloud secret")
	}
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	sealed := s.aead.Seal(nonce, nonce, []byte(plain), []byte("vrpp-cloud-addition-v1"))
	return "vrpp1:" + hex.EncodeToString(sealed), nil
}

func (s secretField) Scan(ctx context.Context, field *schema.Field, dst reflect.Value, value any) error {
	var encoded string
	switch v := value.(type) {
	case string:
		encoded = v
	case []byte:
		encoded = string(v)
	default:
		return errors.New("invalid cloud secret")
	}
	if !strings.HasPrefix(encoded, "vrpp1:") {
		return errors.New("unencrypted cloud secret rejected")
	}
	sealed, err := hex.DecodeString(strings.TrimPrefix(encoded, "vrpp1:"))
	n := s.aead.NonceSize()
	if err != nil || len(sealed) < n+s.aead.Overhead() {
		return errors.New("invalid cloud secret")
	}
	plain, err := s.aead.Open(nil, sealed[:n], sealed[n:], []byte("vrpp-cloud-addition-v1"))
	if err != nil {
		return errors.New("cloud secret cannot be decrypted")
	}
	field.ReflectValueOf(ctx, dst).SetString(string(plain))
	return nil
}

// Request is JNI-only. No credentials, admin token or management route is exposed
// to HTTP clients. Responses containing driver secrets stay in the Android layer.
func Request(method, route, body string) (string, error) {
	requestMu.Lock()
	defer requestMu.Unlock()
	if api == nil || startErr != nil {
		return "", errors.New("cloud unavailable")
	}
	if !strings.HasPrefix(route, "/") || strings.HasPrefix(route, "//") {
		return "", errors.New("invalid cloud route")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	r := httptest.NewRequest(method, route, strings.NewReader(body)).WithContext(ctx)
	token, err := common.GenerateToken(admin)
	if err != nil {
		return "", errors.New("cloud authentication failed")
	}
	defer common.InvalidateToken(token)
	r.Header.Set("Authorization", token)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	api.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		return "", errors.New("cloud request failed")
	}
	return w.Body.String(), nil
}

func Stream(path string) (string, error) {
	if streamBase == "" || startErr != nil {
		return "", errors.New("cloud unavailable")
	}
	if !strings.HasPrefix(path, "/") || strings.Contains(path, "\x00") {
		return "", errors.New("invalid cloud path")
	}
	u := url.URL{Path: path}
	return streamBase + u.EscapedPath(), nil
}

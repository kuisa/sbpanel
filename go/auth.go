package main

// 认证：支持两种凭据来源
//   1) 环境变量 PANEL_USER / PANEL_PASSWORD（安装脚本写进 /etc/sbpanel.env）
//   2) 凭据文件 PANEL_AUTH_FILE（默认 /etc/sbpanel-auth.json，PBKDF2-SHA256 加盐哈希，权限 0600）
// 两者都没有时进入「首次设置」状态：面板只提供设置页，设置完才可用。
// 用户名和密码都会校验（之前只校验密码，用户名随便填）。

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

const pbkdf2Iter = 120000

type authFile struct {
	User string `json:"user"`
	Algo string `json:"algo"`
	Iter int    `json:"iter"`
	Salt string `json:"salt"`
	Hash string `json:"hash"`
}

var (
	authMu    sync.Mutex
	authCache = map[string]bool{} // 认证成功后缓存，避免每个请求都跑一次 PBKDF2
)

func authFilePath() string {
	if v := strings.TrimSpace(os.Getenv("PANEL_AUTH_FILE")); v != "" {
		return v
	}
	return "/etc/sbpanel-auth.json"
}

func envUser() string {
	if v := strings.TrimSpace(os.Getenv("PANEL_USER")); v != "" {
		return v
	}
	return "admin" // 设了密码但没指定用户名时的默认账号
}

func loadAuthFile() (*authFile, error) {
	b, err := os.ReadFile(authFilePath())
	if err != nil {
		return nil, err
	}
	var af authFile
	if err := json.Unmarshal(b, &af); err != nil {
		return nil, err
	}
	if af.User == "" || af.Salt == "" || af.Hash == "" {
		return nil, fmt.Errorf("凭据文件不完整")
	}
	if af.Iter <= 0 {
		af.Iter = pbkdf2Iter
	}
	return &af, nil
}

// 是否已经配置过凭据（没配置就是首次运行，要引导设置）
func authConfigured() bool {
	if os.Getenv("PANEL_PASSWORD") != "" {
		return true
	}
	_, err := loadAuthFile()
	return err == nil
}

func pbkdf2SHA256(password, salt []byte, iter, keyLen int) []byte {
	h := sha256.New
	hashLen := h().Size()
	numBlocks := (keyLen + hashLen - 1) / hashLen
	var buf [4]byte
	dk := make([]byte, 0, numBlocks*hashLen)
	U := make([]byte, hashLen)
	for block := 1; block <= numBlocks; block++ {
		mac := hmac.New(h, password)
		mac.Write(salt)
		buf[0] = byte(block >> 24)
		buf[1] = byte(block >> 16)
		buf[2] = byte(block >> 8)
		buf[3] = byte(block)
		mac.Write(buf[:])
		mac.Sum(U[:0])
		T := make([]byte, hashLen)
		copy(T, U)
		for n := 2; n <= iter; n++ {
			mac = hmac.New(h, password)
			mac.Write(U)
			mac.Sum(U[:0])
			for i := range T {
				T[i] ^= U[i]
			}
		}
		dk = append(dk, T...)
	}
	return dk[:keyLen]
}

// 校验用户名 + 密码
func verifyCredentials(user, pass string) bool {
	if user == "" && pass == "" {
		return false
	}
	// 凭据文件优先（面板里改过的账号存在这里，重启后也不丢）；
	// 没有文件时才回退到环境变量 PANEL_USER / PANEL_PASSWORD。
	af, err := loadAuthFile()
	if err != nil {
		if envPass := os.Getenv("PANEL_PASSWORD"); envPass != "" {
			uOK := subtle.ConstantTimeCompare([]byte(user), []byte(envUser())) == 1
			pOK := subtle.ConstantTimeCompare([]byte(pass), []byte(envPass)) == 1
			return uOK && pOK
		}
		return false
	}
	uOK := subtle.ConstantTimeCompare([]byte(user), []byte(af.User)) == 1
	salt, err := base64.StdEncoding.DecodeString(af.Salt)
	if err != nil {
		return false
	}
	got := pbkdf2SHA256([]byte(pass), salt, af.Iter, 32)
	want, err := base64.StdEncoding.DecodeString(af.Hash)
	if err != nil {
		return false
	}
	pOK := subtle.ConstantTimeCompare(got, want) == 1
	return uOK && pOK
}

// 带缓存：第一次成功后才进缓存，失败一律实算（避免缓存被暴力试探）
func verifyCached(user, pass string) bool {
	key := fmt.Sprintf("%x", sha256.Sum256([]byte(user+"\x00"+pass)))
	authMu.Lock()
	if v, ok := authCache[key]; ok {
		authMu.Unlock()
		return v
	}
	authMu.Unlock()

	ok := verifyCredentials(user, pass)
	if ok {
		authMu.Lock()
		if len(authCache) > 32 {
			authCache = map[string]bool{}
		}
		authCache[key] = true
		authMu.Unlock()
	}
	return ok
}

func clearAuthCache() {
	authMu.Lock()
	authCache = map[string]bool{}
	authMu.Unlock()
}

// 首次设置：写入凭据文件
func saveCredentials(user, password string) error {
	user, password = strings.TrimSpace(user), strings.TrimSpace(password)
	if len(user) < 2 || len(user) > 64 {
		return fmt.Errorf("用户名长度要在 2-64 之间")
	}
	if len(password) < 6 {
		return fmt.Errorf("密码至少 6 位（建议 10 位以上）")
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return err
	}
	hash := pbkdf2SHA256([]byte(password), salt, pbkdf2Iter, 32)
	af := authFile{
		User: user, Algo: "pbkdf2-sha256", Iter: pbkdf2Iter,
		Salt: base64.StdEncoding.EncodeToString(salt),
		Hash: base64.StdEncoding.EncodeToString(hash),
	}
	b, _ := json.MarshalIndent(af, "", "  ")
	path := authFilePath()
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	clearAuthCache()
	return nil
}

// 改密码/换用户名（已登录后用）
func changeCredentials(oldUser, oldPass, newUser, newPass string) error {
	if !authConfigured() {
		return fmt.Errorf("尚未配置凭据")
	}
	// 用「当前生效的账号」校验旧密码（env 模式也能改）
	cur := envUserIfFromFile()
	if !verifyCredentials(cur, oldPass) {
		return fmt.Errorf("当前密码不正确")
	}
	if err := saveCredentials(newUser, newPass); err != nil {
		return err
	}
	// 同步写回 /etc/sbpanel.env，避免重启后 env 里的旧值把新账号顶回去
	if err := syncEnvFile(newUser, newPass); err != nil {
		return fmt.Errorf("账号已生效，但写回 %s 失败（重启后会回到旧账号）: %v", envFilePath(), err)
	}
	return nil
}

// 把新的账号密码写回 /etc/sbpanel.env（保留其它行）
func envFilePath() string {
	if v := strings.TrimSpace(os.Getenv("PANEL_ENV_FILE")); v != "" {
		return v
	}
	return "/etc/sbpanel.env"
}

func syncEnvFile(user, pass string) error {
	path := envFilePath()
	b, err := os.ReadFile(path)
	if err != nil {
		return nil // 没有这个文件就不管（比如用户自己用环境变量启动的）
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	seenU, seenP := false, false
	for i, l := range lines {
		if strings.HasPrefix(l, "PANEL_USER=") {
			lines[i] = "PANEL_USER=" + user
			seenU = true
		} else if strings.HasPrefix(l, "PANEL_PASSWORD=") {
			lines[i] = "PANEL_PASSWORD=" + pass
			seenP = true
		}
	}
	if !seenU {
		lines = append(lines, "PANEL_USER="+user)
	}
	if !seenP {
		lines = append(lines, "PANEL_PASSWORD="+pass)
	}
	out := strings.Join(lines, "\n") + "\n"
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(out), 0o600); err != nil {
		return err
	}
	_ = os.Chmod(tmp, 0o600)
	return os.Rename(tmp, path)
}

func envUserIfFromFile() string {
	if af, err := loadAuthFile(); err == nil {
		return af.User
	}
	return envUser()
}

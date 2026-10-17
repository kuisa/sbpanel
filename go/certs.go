package main

// 证书辅助：给 hysteria2 / tuic / vless+tls 这类需要证书的入站提供
//   1) 列出证书目录里现有的 cert/key
//   2) 一键生成自签证书（openssl）
//   3) 直接粘贴导入自己的证书（省掉传文件）
// 证书目录默认与 config.json 同级的 certs/，可用 SINGBOX_CERT_DIR 覆盖。

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var certNameRe = regexp.MustCompile(`[^A-Za-z0-9._-]`)

func certDirPath() string {
	if v := os.Getenv("SINGBOX_CERT_DIR"); strings.TrimSpace(v) != "" {
		return v
	}
	return filepath.Join(filepath.Dir(E.ConfigPath), "certs")
}

func looksLikeKey(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	buf := make([]byte, 256)
	n, _ := f.Read(buf)
	return strings.Contains(string(buf[:n]), "PRIVATE KEY")
}

type certPair struct {
	Name string `json:"name"`
	Cert string `json:"cert"`
	Key  string `json:"key"`
}

func listCerts() map[string]any {
	dir := certDirPath()
	res := map[string]any{
		"dir": dir, "exists": false,
		"certs": []string{}, "keys": []string{}, "pairs": []certPair{},
	}
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		return res
	}
	res["exists"] = true
	certs, keys := []string{}, []string{}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return res
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		p := filepath.Join(dir, e.Name())
		switch strings.ToLower(filepath.Ext(e.Name())) {
		case ".key":
			keys = append(keys, p)
		case ".crt", ".cer":
			certs = append(certs, p)
		case ".pem":
			if looksLikeKey(p) {
				keys = append(keys, p)
			} else {
				certs = append(certs, p)
			}
		}
	}
	sort.Strings(certs)
	sort.Strings(keys)
	res["certs"], res["keys"] = certs, keys
	// 按同名前缀配对（foo.crt ↔ foo.key / foo.pem ↔ foo.key）
	pairs := []certPair{}
	for _, c := range certs {
		base := strings.TrimSuffix(filepath.Base(c), filepath.Ext(c))
		for _, k := range keys {
			kb := strings.TrimSuffix(filepath.Base(k), filepath.Ext(k))
			if kb == base || strings.HasPrefix(base, kb) || strings.HasPrefix(kb, base) {
				pairs = append(pairs, certPair{Name: base, Cert: c, Key: k})
				break
			}
		}
	}
	res["pairs"] = pairs
	return res
}

func certSafeName(name, domain string) string {
	n := strings.TrimSpace(name)
	if n == "" {
		n = strings.TrimSpace(domain)
	}
	if n == "" {
		n = "self-signed"
	}
	n = certNameRe.ReplaceAllString(n, "_")
	if len(n) > 64 {
		n = n[:64]
	}
	return n
}

func makeSelfSigned(domain, name string) (map[string]any, error) {
	if _, err := exec.LookPath("openssl"); err != nil {
		return nil, fmt.Errorf("系统里没有 openssl，无法生成自签证书（也可以自己粘贴证书导入）")
	}
	domain = strings.TrimSpace(domain)
	if domain == "" {
		domain = "localhost"
	}
	dir := certDirPath()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("创建证书目录失败: %v", err)
	}
	base := certSafeName(name, domain)
	cert := filepath.Join(dir, base+".crt")
	key := filepath.Join(dir, base+".key")
	if _, err := os.Stat(cert); err == nil {
		return nil, fmt.Errorf("同名证书已存在: %s", cert)
	}
	code, out, errs := run("openssl", "req", "-x509", "-newkey", "ec",
		"-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "3650",
		"-keyout", key, "-out", cert,
		"-subj", "/CN="+domain,
		"-addext", "subjectAltName=DNS:"+domain)
	if code != 0 {
		return nil, fmt.Errorf("openssl 生成失败: %s", strings.TrimSpace(errs+out))
	}
	_ = os.Chmod(key, 0o600)
	_ = os.Chmod(cert, 0o644)
	return map[string]any{
		"ok": true, "certificate_path": cert, "key_path": key, "dir": dir, "domain": domain,
		"msg": "已生成自签证书（有效期 10 年）",
	}, nil
}

// 用 sing-box 自己生成 Reality 密钥对（私钥填服务端，公钥给客户端）
func genRealityKeypair() (map[string]any, error) {
	if !binAvailable() {
		return nil, fmt.Errorf("找不到 sing-box（%s），无法生成密钥", E.Bin)
	}
	code, out, errs := run(E.Bin, "generate", "reality-keypair")
	if code != 0 {
		return nil, fmt.Errorf("生成失败: %s", strings.TrimSpace(errs+out))
	}
	priv, pub := "", ""
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if v, ok := strings.CutPrefix(line, "PrivateKey:"); ok {
			priv = strings.TrimSpace(v)
		}
		if v, ok := strings.CutPrefix(line, "PublicKey:"); ok {
			pub = strings.TrimSpace(v)
		}
	}
	if priv == "" || pub == "" {
		return nil, fmt.Errorf("解析密钥失败: %s", strings.TrimSpace(out))
	}
	return map[string]any{
		"ok": true, "private_key": priv, "public_key": pub,
		"msg": "已生成 Reality 密钥对\n公钥（填到客户端）: " + pub,
	}, nil
}

// 直接粘贴导入：省掉传文件，内容必须真的是 PEM
func saveCertFiles(name, certPEM, keyPEM string) (map[string]any, error) {
	certPEM, keyPEM = strings.TrimSpace(certPEM), strings.TrimSpace(keyPEM)
	if !strings.Contains(certPEM, "BEGIN CERTIFICATE") {
		return nil, fmt.Errorf("证书内容不对：没找到 BEGIN CERTIFICATE（请粘贴完整的 PEM 文本）")
	}
	if !strings.Contains(keyPEM, "PRIVATE KEY") {
		return nil, fmt.Errorf("私钥内容不对：没找到 PRIVATE KEY（请粘贴完整的 PEM 文本）")
	}
	dir := certDirPath()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("创建证书目录失败: %v", err)
	}
	base := certSafeName(name, "")
	cert := filepath.Join(dir, base+".crt")
	key := filepath.Join(dir, base+".key")
	if err := os.WriteFile(cert, []byte(certPEM+"\n"), 0o644); err != nil {
		return nil, err
	}
	if err := os.WriteFile(key, []byte(keyPEM+"\n"), 0o600); err != nil {
		return nil, err
	}
	return map[string]any{
		"ok": true, "certificate_path": cert, "key_path": key, "dir": dir,
		"msg": "证书已保存",
	}, nil
}

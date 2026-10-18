// sing-box 控制面板 —— Go 版，单文件零外部依赖，前端内嵌进二进制。
//
// 用法:
//
//	go build -trimpath -ldflags "-s -w" -o singbox-panel .
//	PANEL_PORT=3222 SINGBOX_CONFIG=/etc/sing-box/config.json ./singbox-panel
//
// 环境变量与 Node 版完全一致:
//
//	PANEL_PORT / PANEL_HOST / PANEL_PASSWORD / SINGBOX_CONFIG / SINGBOX_BIN /
//	SINGBOX_SERVICE / SINGBOX_LOG
package main

import (
	"bytes"
	"embed"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed panel.html setup.html
var assets embed.FS

type env struct {
	Port       int
	Host       string
	Password   string
	ConfigPath string
	Bin        string
	Service    string
	LogFile    string
}

var E env
var useSystemd bool
var useOpenRC bool

func initEnv() {
	E = env{
		Port:       atoiDefault(os.Getenv("PANEL_PORT"), 3210),
		Host:       def(os.Getenv("PANEL_HOST"), "0.0.0.0"),
		Password:   os.Getenv("PANEL_PASSWORD"),
		ConfigPath: def(os.Getenv("SINGBOX_CONFIG"), "/etc/sing-box/config.json"),
		Bin:        def(os.Getenv("SINGBOX_BIN"), "sing-box"),
		Service:    def(os.Getenv("SINGBOX_SERVICE"), "sing-box"),
		LogFile:    def(os.Getenv("SINGBOX_LOG"), "/tmp/sing-box.log"),
	}
	useSystemd = E.Service != "" && E.Service != "none" && hasSystemd()
	// 没有 systemd 时看有没有 OpenRC（Alpine 等）；两者都没有就由面板自己管进程
	useOpenRC = !useSystemd && E.Service != "" && E.Service != "none" && hasOpenRC()
}

func def(v, d string) string {
	if v == "" {
		return d
	}
	return v
}

func atoiDefault(s string, d int) int {
	if n, err := strconv.Atoi(strings.TrimSpace(s)); err == nil && n > 0 {
		return n
	}
	return d
}

/* ------------------------------------------------------------- 进程工具 */

func run(name string, args ...string) (int, string, string) {
	ctx, cancel := timeoutCtx(20 * time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	err := cmd.Run()
	code := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			code = -1
		}
	}
	return code, out.String(), errb.String()
}

/* --------------------------------------------------- 保序 JSON（omap） */

type omap struct {
	keys []string
	vals map[string]any
}

func newOMap() *omap { return &omap{vals: map[string]any{}} }

func (o *omap) set(k string, v any) {
	if _, ok := o.vals[k]; !ok {
		o.keys = append(o.keys, k)
	}
	o.vals[k] = v
}
func (o *omap) get(k string) (any, bool) { v, ok := o.vals[k]; return v, ok }
func (o *omap) del(k string) {
	if _, ok := o.vals[k]; !ok {
		return
	}
	delete(o.vals, k)
	for i, kk := range o.keys {
		if kk == k {
			o.keys = append(o.keys[:i], o.keys[i+1:]...)
			break
		}
	}
}
func (o *omap) str(k string) string {
	if v, ok := o.vals[k]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}
func (o *omap) obj(k string) *omap {
	if v, ok := o.vals[k]; ok {
		if m, ok := v.(*omap); ok {
			return m
		}
	}
	return nil
}
func (o *omap) arr(k string) []any {
	if v, ok := o.vals[k]; ok {
		if a, ok := v.([]any); ok {
			return a
		}
	}
	return nil
}
func (o *omap) ensureObj(k string) *omap {
	if m := o.obj(k); m != nil {
		return m
	}
	m := newOMap()
	o.set(k, m)
	return m
}
func (o *omap) ensureArr(k string) []any {
	if a := o.arr(k); a != nil {
		return a
	}
	a := []any{}
	o.set(k, a)
	return a
}

func parseJSON(data []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	v, err := parseValue(dec)
	if err != nil {
		return nil, err
	}
	return v, nil
}

func parseValue(dec *json.Decoder) (any, error) {
	t, err := dec.Token()
	if err != nil {
		return nil, err
	}
	return parseFromToken(dec, t)
}

func parseFromToken(dec *json.Decoder, t json.Token) (any, error) {
	if d, ok := t.(json.Delim); ok {
		switch d {
		case '{':
			o := newOMap()
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				key, _ := kt.(string)
				v, err := parseValue(dec)
				if err != nil {
					return nil, err
				}
				o.set(key, v)
			}
			if _, err := dec.Token(); err != nil { // '}'
				return nil, err
			}
			return o, nil
		case '[':
			arr := []any{}
			for dec.More() {
				v, err := parseValue(dec)
				if err != nil {
					return nil, err
				}
				arr = append(arr, v)
			}
			if _, err := dec.Token(); err != nil { // ']'
				return nil, err
			}
			return arr, nil
		}
	}
	return t, nil
}

func marshalIndent(v any) []byte {
	var buf bytes.Buffer
	writeJSON(&buf, v, 0)
	buf.WriteByte('\n')
	return buf.Bytes()
}

// MarshalJSON 让 *omap 走保序编码器；否则 json.Marshal 只会吐出一个空对象。
func (o *omap) MarshalJSON() ([]byte, error) {
	var buf bytes.Buffer
	writeJSON(&buf, o, 0)
	return buf.Bytes(), nil
}

func writeJSON(buf *bytes.Buffer, v any, depth int) {
	pad := strings.Repeat("  ", depth)
	padIn := strings.Repeat("  ", depth+1)
	switch t := v.(type) {
	case *omap:
		if len(t.keys) == 0 {
			buf.WriteString("{}")
			return
		}
		buf.WriteString("{\n")
		for i, k := range t.keys {
			buf.WriteString(padIn)
			kb, _ := json.Marshal(k)
			buf.Write(kb)
			buf.WriteString(": ")
			writeJSON(buf, t.vals[k], depth+1)
			if i < len(t.keys)-1 {
				buf.WriteByte(',')
			}
			buf.WriteByte('\n')
		}
		buf.WriteString(pad + "}")
	case []any:
		if len(t) == 0 {
			buf.WriteString("[]")
			return
		}
		buf.WriteString("[\n")
		for i, e := range t {
			buf.WriteString(padIn)
			writeJSON(buf, e, depth+1)
			if i < len(t)-1 {
				buf.WriteByte(',')
			}
			buf.WriteByte('\n')
		}
		buf.WriteString(pad + "]")
	default:
		b, err := json.Marshal(t)
		if err != nil {
			buf.WriteString("null")
			return
		}
		buf.Write(b)
	}
}

func asObj(v any) *omap {
	if m, ok := v.(*omap); ok {
		return m
	}
	return nil
}

/* ------------------------------------------------------------ 配置文件 */

func readConfig() (*omap, string, error) {
	raw, err := os.ReadFile(E.ConfigPath)
	if err != nil {
		return nil, "", err
	}
	v, err := parseJSON(raw)
	if err != nil {
		return nil, string(raw), fmt.Errorf("JSON 解析失败: %v", err)
	}
	m, ok := v.(*omap)
	if !ok {
		return nil, string(raw), fmt.Errorf("配置根节点必须是对象")
	}
	return m, string(raw), nil
}

func writeConfig(cfg *omap) error {
	text := marshalIndent(cfg)
	if _, err := parseJSON(text); err != nil {
		return fmt.Errorf("生成的配置非法: %v", err)
	}
	// 保留原文件的权限与属主：sing-box 常以非 root 用户运行，
	// 若把配置覆写成 0600 root 属主，服务重启后会读不到配置。
	mode := os.FileMode(0o644)
	uid, gid := -1, -1
	if st, err := os.Stat(E.ConfigPath); err == nil {
		mode = st.Mode().Perm()
		if sys, ok := st.Sys().(*syscall.Stat_t); ok {
			uid, gid = int(sys.Uid), int(sys.Gid)
		}
		bak := E.ConfigPath + ".bak." + time.Now().UTC().Format("2006-01-02T15-04-05.000Z")
		if b, err := os.ReadFile(E.ConfigPath); err == nil {
			_ = os.WriteFile(bak, b, 0o600)
		}
	}
	tmp := filepath.Join(filepath.Dir(E.ConfigPath), fmt.Sprintf(".panel-%d-%d.tmp", os.Getpid(), time.Now().UnixNano()))
	if err := os.WriteFile(tmp, text, mode); err != nil {
		return err
	}
	_ = os.Chmod(tmp, mode)
	if uid >= 0 {
		_ = os.Chown(tmp, uid, gid)
	}
	return os.Rename(tmp, E.ConfigPath)
}

/* --------------------------------------------------------------- 系统指标 */

var (
	cpuMu     sync.Mutex
	lastIdle  uint64
	lastTotal uint64
	haveLast  bool
	ipMu      sync.Mutex
	ipCache   = struct {
		at time.Time
		ip string
	}{}
)

func cpuPercent() (float64, int) {
	f, err := os.Open("/proc/stat")
	if err != nil {
		load, _ := readLoad()
		return load, 0
	}
	defer f.Close()
	var cpu string
	var vals [10]uint64
	var n int
	if _, err := fmt.Fscanf(f, "%s %d %d %d %d %d %d %d %d %d %d", &cpu, &vals[0], &vals[1], &vals[2], &vals[3], &vals[4], &vals[5], &vals[6], &vals[7], &vals[8], &vals[9]); err != nil {
		// 老内核对字段数敏感，退化为按行解析
		line := readFirstLine("/proc/stat")
		fs := strings.Fields(line)
		n = 0
		for i := 1; i < len(fs) && n < 10; i++ {
			v, err := strconv.ParseUint(fs[i], 10, 64)
			if err != nil {
				continue
			}
			vals[n] = v
			n++
		}
	} else {
		n = 10
	}
	var total, idle uint64
	for i := 0; i < n; i++ {
		total += vals[i]
		if i == 3 || i == 4 {
			idle += vals[i]
		}
	}
	cores := 0
	if b, err := os.ReadFile("/proc/cpuinfo"); err == nil {
		cores = strings.Count(string(b), "processor\t")
		if cores == 0 {
			cores = strings.Count(string(b), "processor")
		}
	}
	if cores == 0 {
		cores = 1
	}
	cpuMu.Lock()
	defer cpuMu.Unlock()
	if !haveLast {
		lastIdle, lastTotal, haveLast = idle, total, true
		return 0, cores
	}
	di, dt := idle-lastIdle, total-lastTotal
	lastIdle, lastTotal = idle, total
	if dt == 0 {
		return 0, cores
	}
	pct := 100 * (1 - float64(di)/float64(dt))
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	return pct, cores
}

func readLoad() (float64, error) {
	b, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return 0, err
	}
	f := strings.Fields(string(b))
	if len(f) == 0 {
		return 0, fmt.Errorf("empty")
	}
	return strconv.ParseFloat(f[0], 64)
}

func readFirstLine(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	s := string(b)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func memStats() (total, used, free uint64, pct float64) {
	b, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, 0, 0, 0
	}
	var avail uint64
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		v, _ := strconv.ParseUint(f[1], 10, 64)
		switch f[0] {
		case "MemTotal:":
			total = v * 1024
		case "MemAvailable:":
			avail = v * 1024
		case "MemFree:":
			free = v * 1024
		}
	}
	if avail == 0 {
		avail = free
	}
	used = total - avail
	if total > 0 {
		pct = float64(used) / float64(total) * 100
	}
	return
}

func diskUsage(path string) map[string]any {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return nil
	}
	bs := uint64(st.Bsize)
	total := st.Blocks * bs
	free := st.Bavail * bs
	used := total - st.Bfree*bs
	pct := 0.0
	if total > 0 {
		pct = float64(used) / float64(total) * 100
	}
	return map[string]any{
		"mount": path, "total": total, "used": used, "free": free,
		"percent": round1(pct),
	}
}

func round1(f float64) float64 {
	return float64(int(f*10+0.5)) / 10
}

func uptimeSeconds() float64 {
	b, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0
	}
	f := strings.Fields(string(b))
	if len(f) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(f[0], 64)
	return v
}

func loadavg() []float64 {
	b, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return []float64{0, 0, 0}
	}
	f := strings.Fields(string(b))
	out := []float64{}
	for i := 0; i < 3 && i < len(f); i++ {
		v, _ := strconv.ParseFloat(f[i], 64)
		out = append(out, v)
	}
	for len(out) < 3 {
		out = append(out, 0)
	}
	return out
}

func exitIP() string {
	ipMu.Lock()
	defer ipMu.Unlock()
	if time.Since(ipCache.at) < 60*time.Second && ipCache.ip != "" {
		return ipCache.ip
	}
	urls := []string{
		"https://api.ipify.org?format=json",
		"https://ipv4.icanhazip.com/",
		"https://ifconfig.me/ip",
	}
	client := &http.Client{Timeout: 6 * time.Second}
	for _, u := range urls {
		req, _ := http.NewRequest("GET", u, nil)
		req.Header.Set("user-agent", "curl/8")
		resp, err := client.Do(req)
		if err != nil {
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		s := strings.TrimSpace(string(body))
		var parsed map[string]any
		if json.Unmarshal(body, &parsed) == nil {
			if v, ok := parsed["ip"].(string); ok {
				s = v
			}
		}
		if s != "" && isIPish(s) {
			ipCache.at, ipCache.ip = time.Now(), s
			return s
		}
	}
	return ipCache.ip
}

func isIPish(s string) bool {
	if s == "" || len(s) > 45 {
		return false
	}
	for _, c := range s {
		if !(c == '.' || c == ':' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}

/* --------------------------------------------------------- sing-box 控制 */

func hasSystemd() bool {
	if _, err := os.Stat("/run/systemd/system"); err != nil {
		return false
	}
	_, err := exec.LookPath("systemctl")
	return err == nil
}

func hasOpenRC() bool {
	if _, err := exec.LookPath("rc-service"); err != nil {
		return false
	}
	// 容器/chroot 里 openrc 没有接管 init，rc-service 会拒绝执行
	_, err := os.Stat("/run/openrc")
	return err == nil
}

func binAvailable() bool {
	if _, err := exec.LookPath(E.Bin); err == nil {
		return true
	}
	_, err := os.Stat(E.Bin)
	return err == nil
}

// systemctl/进程返回成功不代表 sing-box 真的接受了配置：
// reload 与 restart 都要等状态稳定后再判定，否则会给用户假成功。
func waitActive(timeout time.Duration) (bool, string) {
	deadline := time.Now().Add(timeout)
	last := "unknown"
	for {
		code, out, _ := run("systemctl", "is-active", E.Service)
		last = strings.TrimSpace(out)
		if code == 0 && last == "active" {
			return true, last
		}
		if time.Now().After(deadline) {
			return false, last
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// sing-box 只允许会真正拨号的出站挂 detour；direct/block/组出站挂了会被 FATAL 拒绝。
func detourUnsupported(t string) bool {
	switch t {
	case "direct", "block", "dns", "selector", "urltest":
		return true
	}
	return false
}

func binVersion() string {
	code, out, _ := run(E.Bin, "version")
	if code != 0 {
		return ""
	}
	line := strings.SplitN(out, "\n", 2)[0]
	return strings.TrimSpace(line)
}

func pidFile() string { return filepath.Join(os.TempDir(), "panel-singbox.pid") }

func alivePid(pid int) bool {
	if pid <= 0 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}

func findPid() int {
	if b, err := os.ReadFile(pidFile()); err == nil {
		if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && alivePid(pid) {
			return pid
		}
	}
	code, out, _ := run("pgrep", "-f", "sing[-]box")
	if code == 0 {
		for _, l := range strings.Split(out, "\n") {
			if pid, err := strconv.Atoi(strings.TrimSpace(l)); err == nil && alivePid(pid) {
				return pid
			}
		}
	}
	return 0
}

func serviceState() map[string]any {
	st := map[string]any{"version": binVersion()}
	if useSystemd {
		code, out, _ := run("systemctl", "is-active", E.Service)
		state := strings.TrimSpace(out)
		if state == "" {
			state = "unknown"
		}
		_, pidOut, _ := run("systemctl", "show", "-p", "MainPID", "--value", E.Service)
		pid, _ := strconv.Atoi(strings.TrimSpace(pidOut))
		st["mode"] = "systemd"
		st["unit"] = E.Service
		st["state"] = state
		st["running"] = state == "active"
		st["pid"] = pid
		if code < 0 {
			st["state"] = "unknown"
		}
		return st
	}
	if useOpenRC {
		_, out, _ := run("rc-service", E.Service, "status")
		txt := strings.TrimSpace(out)
		running := strings.Contains(txt, "started")
		pid := findPid()
		st["mode"] = "openrc"
		st["unit"] = E.Service
		st["state"] = map[bool]string{true: "active", false: "inactive"}[running]
		st["running"] = running
		st["pid"] = pid
		return st
	}
	pid := findPid()
	st["mode"] = "process"
	st["unit"] = E.Service
	st["state"] = map[bool]string{true: "active", false: "inactive"}[pid > 0]
	st["running"] = pid > 0
	st["pid"] = pid
	return st
}

func tailLines(s string, n int) string {
	all := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(all) > n {
		all = all[len(all)-n:]
	}
	return strings.Join(all, "\n")
}

func checkConfig() (bool, string) {
	code, out, errs := run(E.Bin, "check", "-c", E.ConfigPath)
	msg := strings.TrimSpace(out + errs)
	return code == 0, msg
}

func control(action string) (bool, string) {
	if useSystemd {
		if action == "reload" {
			code, _, errs := run("systemctl", "reload", E.Service)
			if code != 0 {
				return false, "reload 命令失败: " + strings.TrimSpace(errs)
			}
			if ok, st := waitActive(3 * time.Second); !ok {
				return false, "reload 后服务未回到 active（当前 " + st + "）：sing-box 拒绝了新配置，详见日志"
			}
			return true, "已 reload"
		}
		code, out, errs := run("systemctl", action, E.Service)
		msg := strings.TrimSpace(out + errs)
		if msg == "" {
			msg = action + " 完成"
		}
		if code != 0 {
			return false, msg
		}
		if action == "stop" {
			deadline := time.Now().Add(3 * time.Second)
			for time.Now().Before(deadline) {
				if _, st, _ := run("systemctl", "is-active", E.Service); strings.TrimSpace(st) != "active" {
					break
				}
				time.Sleep(200 * time.Millisecond)
			}
			return true, "已停止"
		}
		if ok, st := waitActive(6 * time.Second); !ok {
			return false, "命令已执行但服务未进入 active（当前 " + st + "）：检查配置与日志"
		}
		return true, msg
	}
	if useOpenRC {
		if action == "reload" {
			// openrc 的 reload 语义依服务而定，直接给 sing-box 发 HUP（它支持热重载）
			pid := findPid()
			if pid <= 0 {
				return false, "服务没在运行，无法 reload"
			}
			if err := syscall.Kill(pid, syscall.SIGHUP); err != nil {
				return false, "发送 HUP 失败: " + err.Error()
			}
			return true, "已 reload（SIGHUP）"
		}
		code, out, errs := run("rc-service", E.Service, action)
		msg := strings.TrimSpace(out + errs)
		if msg == "" {
			msg = action + " 完成"
		}
		if code != 0 {
			return false, msg
		}
		if action != "stop" {
			time.Sleep(700 * time.Millisecond)
			_, st2, _ := run("rc-service", E.Service, "status")
			if !strings.Contains(st2, "started") {
				return false, "命令已执行但服务未启动（rc-service status 显示未运行）：检查配置与日志"
			}
		}
		return true, msg
	}
	st := serviceState()
	pid, _ := st["pid"].(int)
	switch action {
	case "stop":
		if pid > 0 {
			_ = syscall.Kill(-pid, syscall.SIGTERM)
			_ = syscall.Kill(pid, syscall.SIGTERM)
			return true, fmt.Sprintf("已停止 (pid %d)", pid)
		}
		return true, "本来就没在跑"
	}
	if action == "restart" && pid > 0 {
		_ = syscall.Kill(-pid, syscall.SIGTERM)
		_ = syscall.Kill(pid, syscall.SIGTERM)
		time.Sleep(800 * time.Millisecond)
	}
	if ok, msg := checkConfig(); !ok {
		return false, "配置检查失败: " + msg
	}
	logf, err := os.OpenFile(E.LogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return false, "无法写日志文件: " + err.Error()
	}
	defer logf.Close()
	cmd := exec.Command(E.Bin, "run", "-c", E.ConfigPath)
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return false, "启动失败: " + err.Error()
	}
	_ = os.WriteFile(pidFile(), []byte(strconv.Itoa(cmd.Process.Pid)), 0o644)
	_ = cmd.Process.Release()
	time.Sleep(600 * time.Millisecond)
	if alivePid(cmd.Process.Pid) {
		return true, fmt.Sprintf("已启动 (pid %d)", cmd.Process.Pid)
	}
	return false, "启动后进程未存活，检查日志"
}

func logs(lines int) string {
	if lines <= 0 {
		lines = 200
	}
	if lines > 2000 {
		lines = 2000
	}
	if useSystemd {
		code, out, errs := run("journalctl", "-u", E.Service, "-n", strconv.Itoa(lines), "--no-pager")
		if code == 0 {
			return out
		}
		return strings.TrimSpace(errs) + "\n(journalctl 不可用)"
	}
	if useOpenRC {
		for _, f := range []string{"/var/log/sing-box.log", E.LogFile} {
			if b, err := os.ReadFile(f); err == nil {
				return tailLines(string(b), lines)
			}
		}
		return "(暂无日志：OpenRC 模式下请查看 /var/log/sing-box.log)"
	}
	b, err := os.ReadFile(E.LogFile)
	if err != nil {
		return "(暂无日志文件 " + E.LogFile + ")"
	}
	all := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(all) > lines {
		all = all[len(all)-lines:]
	}
	return strings.Join(all, "\n")
}

/* ------------------------------------------------------------- 链路推导 */

func tagOf(o *omap) string { return o.str("tag") }

func asObjList(v any) []*omap {
	arr, ok := v.([]any)
	if !ok {
		return nil
	}
	out := []*omap{}
	for _, e := range arr {
		if m, ok := e.(*omap); ok {
			out = append(out, m)
		}
	}
	return out
}

func num(v any) int64 {
	switch t := v.(type) {
	case json.Number:
		n, _ := t.Int64()
		return n
	case float64:
		return int64(t)
	}
	return 0
}

func buildGraph(cfg *omap) map[string]any {
	inbounds := []map[string]any{}
	for _, i := range asObjList(cfg.arr("inbounds")) {
		inbounds = append(inbounds, map[string]any{
			"tag": tagOf(i), "type": i.str("type"),
			"listen": i.str("listen"), "port": num(func() any { v, _ := i.get("listen_port"); return v }()),
		})
	}
	outbounds := []map[string]any{}
	for _, o := range asObjList(cfg.arr("outbounds")) {
		outbounds = append(outbounds, map[string]any{
			"tag": tagOf(o), "type": o.str("type"), "detour": o.str("detour"),
			"server": o.str("server"), "port": num(func() any { v, _ := o.get("server_port"); return v }()),
		})
	}
	edges := []map[string]string{}
	route := cfg.obj("route")
	if route != nil {
		for _, r := range asObjList(route.arr("rules")) {
			out := r.str("outbound")
			if out == "" {
				continue
			}
			ins := []string{}
			if a, ok := r.get("inbound"); ok {
				if list, ok := a.([]any); ok {
					for _, x := range list {
						if s, ok := x.(string); ok {
							ins = append(ins, s)
						}
					}
				}
			}
			if len(ins) == 0 {
				edges = append(edges, map[string]string{"from": "*", "to": out, "kind": "default"})
				continue
			}
			for _, it := range ins {
				edges = append(edges, map[string]string{"from": it, "to": out, "kind": "route"})
			}
		}
		if fin := route.str("final"); fin != "" {
			edges = append(edges, map[string]string{"from": "*", "to": fin, "kind": "final"})
		}
	}
	for _, o := range outbounds {
		if o["detour"] != "" {
			edges = append(edges, map[string]string{"from": o["tag"].(string), "to": o["detour"].(string), "kind": "detour"})
		}
	}
	routed := map[string]bool{}
	referenced := map[string]bool{}
	for _, e := range edges {
		switch e["kind"] {
		case "route":
			routed[e["from"]] = true
			referenced[e["to"]] = true
		case "final", "default":
			referenced[e["to"]] = true
		}
	}
	unbound, unused := []string{}, []string{}
	for _, i := range inbounds {
		if !routed[i["tag"].(string)] {
			unbound = append(unbound, i["tag"].(string))
		}
	}
	for _, o := range outbounds {
		t := o["tag"].(string)
		if !referenced[t] && o["detour"] == "" {
			unused = append(unused, t)
		}
	}
	final := ""
	if route != nil {
		final = route.str("final")
	}
	return map[string]any{
		"inbounds": inbounds, "outbounds": outbounds, "edges": edges,
		"final": final, "unbound": unbound, "unused": unused,
	}
}

func setBind(cfg *omap, inbound, outbound string) {
	route := cfg.ensureObj("route")
	rules := route.ensureArr("rules")
	kept := []any{}
	touched := false
	for _, rv := range rules {
		r, ok := rv.(*omap)
		if !ok {
			kept = append(kept, rv)
			continue
		}
		a, has := r.get("inbound")
		list, _ := a.([]any)
		if !has {
			kept = append(kept, r)
			continue
		}
		contains := false
		for _, x := range list {
			if s, ok := x.(string); ok && s == inbound {
				contains = true
			}
		}
		if !contains {
			kept = append(kept, r)
			continue
		}
		touched = true
		if outbound == "" {
			nl := []any{}
			for _, x := range list {
				if s, ok := x.(string); ok && s == inbound {
					continue
				}
				nl = append(nl, x)
			}
			if len(nl) == 0 {
				continue // 整条规则丢弃
			}
			r.set("inbound", nl)
			kept = append(kept, r)
			continue
		}
		r.set("outbound", outbound)
		kept = append(kept, r)
	}
	if outbound != "" && !touched {
		nr := newOMap()
		nr.set("inbound", []any{inbound})
		nr.set("outbound", outbound)
		kept = append(kept, nr)
	}
	route.set("rules", kept)
}

func setDetour(cfg *omap, outboundTag, detourTag string) error {
	list := asObjList(cfg.arr("outbounds"))
	var target *omap
	for _, o := range list {
		if tagOf(o) == outboundTag {
			target = o
		}
	}
	if target == nil {
		return fmt.Errorf("找不到出站: %s", outboundTag)
	}
	if detourTag == "" {
		target.del("detour")
		return nil
	}
	if detourUnsupported(target.str("type")) {
		return fmt.Errorf("%s 类型出站不支持链式：sing-box 会直接 FATAL（detour is not supported in direct context）；只有真正拨号的出站（vless / trojan / shadowsocks / socks / hysteria2 等）才能挂 detour",
			target.str("type"))
	}
	if detourTag == outboundTag {
		return fmt.Errorf("链路不能指向自己")
	}
	found := false
	for _, o := range list {
		if tagOf(o) == detourTag {
			found = true
		}
	}
	if !found {
		return fmt.Errorf("找不到出站: %s", detourTag)
	}
	cur, guard := detourTag, 0
	for cur != "" && guard < 50 {
		if cur == outboundTag {
			return fmt.Errorf("会形成环路：%s → %s", outboundTag, detourTag)
		}
		next := ""
		for _, o := range list {
			if tagOf(o) == cur {
				next = o.str("detour")
			}
		}
		cur = next
		guard++
	}
	target.set("detour", detourTag)
	return nil
}

/* ---------------------------------------------------------------- HTTP */

// 写操作后顺带跑一次 sing-box check，让前端能立刻提示「配置被 sing-box 拒绝」。
// sing-box 没装时返回 nil，不产生噪音。
func checkPayload() map[string]any {
	if !binAvailable() {
		return nil
	}
	ok, out := checkConfig()
	if strings.TrimSpace(out) == "" {
		out = "(无输出)"
	}
	return map[string]any{"ok": ok, "output": out}
}

func withCheck(m map[string]any) map[string]any {
	if c := checkPayload(); c != nil {
		m["check"] = c
	}
	return m
}

func jsonResp(w http.ResponseWriter, code int, v any) {
	w.Header().Set("content-type", "application/json; charset=utf-8")
	w.Header().Set("cache-control", "no-store")
	w.WriteHeader(code)
	if s, ok := v.(string); ok {
		w.Write([]byte(s))
		return
	}
	b, err := json.Marshal(v)
	if err != nil {
		w.Write([]byte(`{"error":"encode failed"}`))
		return
	}
	w.Write(b)
}

func basicCreds(r *http.Request) (string, string, bool) {
	h := r.Header.Get("authorization")
	if !strings.HasPrefix(h, "Basic ") {
		return "", "", false
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(h[6:]))
	if err != nil {
		return "", "", false
	}
	i := strings.IndexByte(string(raw), ':')
	if i < 0 {
		return "", "", false
	}
	return string(raw)[:i], string(raw)[i+1:], true
}

// 用户名 + 密码都要对（密码为空=未配置 → 交给首次设置流程，不再默认放行）
func authed(r *http.Request) bool {
	if !authConfigured() {
		return false
	}
	u, pw, ok := basicCreds(r)
	if !ok {
		return false
	}
	return verifyCached(u, pw)
}

func readBody(r *http.Request) (*omap, error) {
	data, err := io.ReadAll(io.LimitReader(r.Body, 16*1024*1024))
	if err != nil {
		return nil, err
	}
	if len(bytes.TrimSpace(data)) == 0 {
		return newOMap(), nil
	}
	v, err := parseJSON(data)
	if err != nil {
		return nil, fmt.Errorf("请求体不是合法 JSON")
	}
	m, ok := v.(*omap)
	if !ok {
		return nil, fmt.Errorf("请求体必须是 JSON 对象")
	}
	return m, nil
}

func handler(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Path
	q := r.URL.Query()

	// 还没配置任何凭据 → 只提供首次设置页
	if !authConfigured() {
		switch {
		case p == "/setup" || p == "/":
			html, err := assets.ReadFile("setup.html")
			if err != nil {
				jsonResp(w, 500, map[string]any{"error": err.Error()})
				return
			}
			w.Header().Set("content-type", "text/html; charset=utf-8")
			w.Write(html)
			return
		case p == "/api/setup" && r.Method == "POST":
			body, err := readBody(r)
			if err != nil {
				jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
				return
			}
			if err := saveCredentials(body.str("user"), body.str("password")); err != nil {
				jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
				return
			}
			jsonResp(w, 200, map[string]any{"ok": true, "msg": "账号已设置"})
			return
		case p == "/api/auth/state":
			jsonResp(w, 200, map[string]any{"configured": false, "setup_required": true, "setup_url": "/setup"})
			return
		default:
			jsonResp(w, 401, map[string]any{
				"error": "面板还没设置账号", "setup_required": true, "setup_url": "/setup",
			})
			return
		}
	}

	if !authed(r) {
		w.Header().Set("www-authenticate", `Basic realm="sbpanel"`)
		jsonResp(w, 401, map[string]any{"error": "用户名或密码不正确"})
		return
	}
	switch {
	case p == "/" || p == "/index.html":
		html, err := assets.ReadFile("panel.html")
		if err != nil {
			jsonResp(w, 500, map[string]any{"error": err.Error()})
			return
		}
		w.Header().Set("content-type", "text/html; charset=utf-8")
		w.Write(html)

	case p == "/api/status" && r.Method == "GET":
		pct, cores := cpuPercent()
		total, used, free, mpct := memStats()
		ip := exitIP()
		var disk map[string]any
		if d := diskUsage("/"); d != nil {
			disk = d
		}
		cfgOK, cfgErr := false, ""
		if _, _, err := readConfig(); err == nil {
			cfgOK = true
		} else {
			cfgErr = err.Error()
		}
		_, statErr := os.Stat(E.ConfigPath)
		jsonResp(w, 200, map[string]any{
			"cpu":         map[string]any{"percent": round1(pct), "cores": cores},
			"mem":         map[string]any{"total": total, "used": used, "free": free, "percent": round1(mpct)},
			"disk":        disk,
			"exitIp":      ip,
			"ipCheckedAt": time.Now().UnixMilli(),
			"loadavg":     loadavg(),
			"uptime":      uptimeSeconds(),
			"hostname":    hostname(),
			"platform":    "linux " + goArch(),
			"service":     serviceState(),
			"config": map[string]any{
				"path": E.ConfigPath, "exists": statErr == nil,
				"valid": cfgOK, "error": cfgErr,
			},
			"now": time.Now().UnixMilli(),
		})

	case p == "/api/config" && r.Method == "GET":
		cfg, raw, err := readConfig()
		if err != nil {
			jsonResp(w, 200, map[string]any{"ok": false, "error": err.Error(), "raw": raw, "graph": nil})
			return
		}
		jsonResp(w, 200, map[string]any{"ok": true, "raw": raw, "config": cfg, "graph": buildGraph(cfg)})

	case p == "/api/config" && r.Method == "PUT":
		body, err := readBody(r)
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		var obj *omap
		if raw := body.str("raw"); raw != "" {
			v, err := parseJSON([]byte(raw))
			if err != nil {
				jsonResp(w, 400, map[string]any{"ok": false, "error": "JSON 解析失败: " + err.Error()})
				return
			}
			obj, _ = v.(*omap)
		} else if c := body.obj("config"); c != nil {
			obj = c
		}
		if obj == nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": "缺少 raw 或 config"})
			return
		}
		if err := writeConfig(obj); err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		jsonResp(w, 200, withCheck(map[string]any{"ok": true, "msg": "已保存", "graph": buildGraph(obj)}))

	case p == "/api/config/check" && r.Method == "POST":
		ok, out := checkConfig()
		jsonResp(w, 200, map[string]any{"ok": ok, "output": out})

	case p == "/api/bind" && r.Method == "POST":
		body, err := readBody(r)
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		cfg, _, err := readConfig()
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		in := body.str("inbound")
		if in == "" {
			jsonResp(w, 400, map[string]any{"ok": false, "error": "缺少 inbound"})
			return
		}
		setBind(cfg, in, body.str("outbound"))
		if err := writeConfig(cfg); err != nil {
			jsonResp(w, 500, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		jsonResp(w, 200, withCheck(map[string]any{"ok": true, "graph": buildGraph(cfg)}))

	case p == "/api/chain" && r.Method == "POST":
		body, err := readBody(r)
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		cfg, _, err := readConfig()
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if err := setDetour(cfg, body.str("outbound"), body.str("detour")); err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if err := writeConfig(cfg); err != nil {
			jsonResp(w, 500, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		jsonResp(w, 200, withCheck(map[string]any{"ok": true, "graph": buildGraph(cfg)}))

	case p == "/api/object" && r.Method == "POST":
		body, err := readBody(r)
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		cfg, _, err := readConfig()
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		key := "outbounds"
		if body.str("kind") == "inbound" {
			key = "inbounds"
		}
		data := body.obj("data")
		if data == nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": "缺少 data"})
			return
		}
		if tagOf(data) == "" {
			jsonResp(w, 400, map[string]any{"ok": false, "error": "必须填写 tag"})
			return
		}
		orig := body.str("original")
		list := cfg.ensureArr(key)
		replaced := false
		for i, e := range list {
			if m, ok := e.(*omap); ok && tagOf(m) == orig && orig != "" {
				list[i] = data
				replaced = true
				break
			}
		}
		if !replaced {
			list = append(list, data)
		}
		cfg.set(key, list)
		if err := writeConfig(cfg); err != nil {
			jsonResp(w, 500, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		jsonResp(w, 200, withCheck(map[string]any{"ok": true, "graph": buildGraph(cfg)}))

	case p == "/api/object" && r.Method == "DELETE":
		kind, tag := q.Get("kind"), q.Get("tag")
		cfg, _, err := readConfig()
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		key := "outbounds"
		if kind == "inbound" {
			key = "inbounds"
		}
		list := cfg.ensureArr(key)
		kept := []any{}
		for _, e := range list {
			if m, ok := e.(*omap); ok && tagOf(m) == tag {
				continue
			}
			kept = append(kept, e)
		}
		cfg.set(key, kept)
		if kind == "outbound" {
			for _, o := range asObjList(cfg.arr("outbounds")) {
				if o.str("detour") == tag {
					o.del("detour")
				}
			}
			route := cfg.ensureObj("route")
			if route.arr("rules") != nil {
				nr := []any{}
				for _, rv := range route.arr("rules") {
					if m, ok := rv.(*omap); ok && m.str("outbound") == tag {
						continue
					}
					nr = append(nr, rv)
				}
				route.set("rules", nr)
			}
			if route.str("final") == tag {
				rest := asObjList(cfg.arr("outbounds"))
				if len(rest) > 0 {
					route.set("final", tagOf(rest[0]))
				} else {
					route.del("final")
				}
			}
		} else {
			route := cfg.obj("route")
			if route != nil && route.obj("rules") != nil {
				nr := []any{}
				for _, rv := range route.arr("rules") {
					m, ok := rv.(*omap)
					if !ok {
						nr = append(nr, rv)
						continue
					}
					if a, ok := m.get("inbound"); ok {
						if list2, ok := a.([]any); ok {
							nl := []any{}
							for _, x := range list2 {
								if s, ok := x.(string); ok && s == tag {
									continue
								}
								nl = append(nl, x)
							}
							if len(nl) == 0 {
								continue
							}
							m.set("inbound", nl)
						}
					}
					nr = append(nr, m)
				}
				route.set("rules", nr)
			}
		}
		if err := writeConfig(cfg); err != nil {
			jsonResp(w, 500, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		jsonResp(w, 200, withCheck(map[string]any{"ok": true, "graph": buildGraph(cfg)}))

	case p == "/api/service" && r.Method == "POST":
		body, err := readBody(r)
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		action := body.str("action")
		if action != "start" && action != "stop" && action != "restart" && action != "reload" {
			jsonResp(w, 400, map[string]any{"ok": false, "error": "不支持的动作"})
			return
		}
		if action == "start" || action == "restart" || action == "reload" {
			if _, _, err := readConfig(); err != nil {
				jsonResp(w, 400, map[string]any{"ok": false, "error": "配置无效，拒绝启动: " + err.Error()})
				return
			}
			// JSON 合法 ≠ sing-box 接受：先让 sing-box 自己 check 一遍，
			// 否则会把服务重启到一个起不来的配置上。
			if binAvailable() {
				if ok, out := checkConfig(); !ok {
					jsonResp(w, 400, map[string]any{"ok": false, "error": "sing-box 拒绝该配置，已取消操作: " + out})
					return
				}
			}
		}
		ok, msg := control(action)
		code := 200
		if !ok {
			code = 400
		}
		jsonResp(w, code, map[string]any{"ok": ok, "msg": msg})

	case p == "/api/logs" && r.Method == "GET":
		n, _ := strconv.Atoi(q.Get("lines"))
		jsonResp(w, 200, map[string]any{"ok": true, "log": logs(n)})

	case p == "/api/export" && r.Method == "GET":
		raw, err := os.ReadFile(E.ConfigPath)
		if err != nil {
			jsonResp(w, 404, "配置文件不存在")
			return
		}
		w.Header().Set("content-type", "application/json; charset=utf-8")
		w.Header().Set("content-disposition", `attachment; filename="config.json"`)
		w.Write(raw)

	case p == "/api/auth/state" && r.Method == "GET":
		user, src := envUser(), "env"
		if af, err := loadAuthFile(); err == nil {
			user, src = af.User, "file"
		}
		jsonResp(w, 200, map[string]any{
			"configured": true, "user": user, "source": src,
			"can_change": true, "auth_file": authFilePath(), "env_file": envFilePath(),
		})

	case p == "/api/auth/change" && r.Method == "POST":
		body, err := readBody(r)
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if err := changeCredentials(body.str("old_user"), body.str("old_password"), body.str("user"), body.str("password")); err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		jsonResp(w, 200, map[string]any{"ok": true, "msg": "账号已更新，请用新账号重新登录"})

	case p == "/api/backups" && r.Method == "GET":
		jsonResp(w, 200, listBackups())

	case p == "/api/config/restore" && r.Method == "POST":
		body, err := readBody(r)
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		res, err := restoreBackup(body.str("file"))
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		jsonResp(w, 200, res)

	case p == "/api/gen/reality" && r.Method == "POST":
		res, err := genRealityKeypair()
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		jsonResp(w, 200, res)

	case p == "/api/certs" && r.Method == "GET":
		jsonResp(w, 200, listCerts())

	case p == "/api/certs/selfsigned" && r.Method == "POST":
		body, err := readBody(r)
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		res, err := makeSelfSigned(body.str("domain"), body.str("name"))
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		jsonResp(w, 200, res)

	case p == "/api/certs/upload" && r.Method == "POST":
		body, err := readBody(r)
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		res, err := saveCertFiles(body.str("name"), body.str("cert"), body.str("key"))
		if err != nil {
			jsonResp(w, 400, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		jsonResp(w, 200, res)

	default:
		jsonResp(w, 404, map[string]any{"error": "not found"})
	}
}

func main() {
	initEnv()
	srv := &http.Server{
		Addr:              fmt.Sprintf("%s:%d", E.Host, E.Port),
		Handler:           http.HandlerFunc(handler),
		ReadHeaderTimeout: 10 * time.Second,
	}
	fmt.Printf("sing-box 面板已启动: http://%s:%d\n", E.Host, E.Port)
	fmt.Printf("  配置: %s\n", E.ConfigPath)
	if useSystemd {
		fmt.Printf("  控制: systemd %s\n", E.Service)
	} else if useOpenRC {
		fmt.Printf("  控制: OpenRC %s\n", E.Service)
	} else {
		fmt.Printf("  控制: 直接进程 (%s)\n", E.Bin)
	}
	if E.Password != "" {
		fmt.Println("  登录: 已启用")
	} else {
		fmt.Println("  登录: 未启用 (设置 PANEL_PASSWORD 开启)")
	}
	if err := srv.ListenAndServe(); err != nil {
		fmt.Fprintln(os.Stderr, "启动失败:", err)
		os.Exit(1)
	}
}

#!/usr/bin/env node
/**
 * sing-box 控制面板 —— 零依赖单文件后端
 *
 * 用法:
 *   node server.js
 *   PANEL_PORT=3210 SINGBOX_CONFIG=/etc/sing-box/config.json node server.js
 *
 * 环境变量:
 *   PANEL_PORT        面板端口          默认 3210
 *   PANEL_HOST        监听地址          默认 0.0.0.0
 *   PANEL_PASSWORD    面板登录密码      留空 = 不启用登录
 *   SINGBOX_CONFIG    sing-box 配置路径 默认 /etc/sing-box/config.json
 *   SINGBOX_BIN       sing-box 可执行   默认 sing-box
 *   SINGBOX_SERVICE   systemd 服务名    默认 sing-box；填 none 则直接管理进程
 *   SINGBOX_LOG       直管模式的日志    默认 /tmp/sing-box.log
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFile, spawn } = require('child_process');

const ENV = {
  port: parseInt(process.env.PANEL_PORT || '3210', 10),
  host: process.env.PANEL_HOST || '0.0.0.0',
  password: process.env.PANEL_PASSWORD || '',
  configPath: process.env.SINGBOX_CONFIG || '/etc/sing-box/config.json',
  bin: process.env.SINGBOX_BIN || 'sing-box',
  service: process.env.SINGBOX_SERVICE || 'sing-box',
  logFile: process.env.SINGBOX_LOG || '/tmp/sing-box.log',
};
const USE_SYSTEMD = ENV.service && ENV.service !== 'none';
const UI_FILE = path.join(__dirname, 'panel.html');

/* ------------------------------------------------------------------ utils */

function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: 15000, maxBuffer: 8 * 1024 * 1024, ...opts },
      (err, stdout, stderr) => resolve({
        code: err ? (err.code === undefined ? -1 : err.code) : 0,
        out: (stdout || '').toString(),
        err: (stderr || '').toString(),
      }));
  });
}

function readConfigRaw() {
  try {
    const raw = fs.readFileSync(ENV.configPath, 'utf8');
    return { ok: true, raw };
  } catch (e) {
    return { ok: false, raw: '', error: e.message };
  }
}

function readConfig() {
  const r = readConfigRaw();
  if (!r.ok) return { ok: false, error: r.error, raw: '', config: null };
  try {
    return { ok: true, raw: r.raw, config: JSON.parse(r.raw) };
  } catch (e) {
    return { ok: false, error: 'JSON 解析失败: ' + e.message, raw: r.raw, config: null };
  }
}

function writeConfigAtomic(obj) {
  const dir = path.dirname(ENV.configPath);
  const tmp = path.join(dir, '.panel-' + process.pid + '-' + Date.now() + '.tmp');
  const text = JSON.stringify(obj, null, 2) + '\n';
  JSON.parse(text); // 自检
  // 保留原文件权限与属主：sing-box 常以非 root 用户运行，覆写成 0600 root 会让服务读不到配置
  let mode = 0o644, uid = -1, gid = -1;
  try {
    const st = fs.statSync(ENV.configPath);
    mode = st.mode & 0o777; uid = st.uid; gid = st.gid;
    const bak = ENV.configPath + '.bak.' + new Date().toISOString().replace(/[:.]/g, '-');
    try { fs.copyFileSync(ENV.configPath, bak); } catch (_) {}
  } catch (_) {}
  fs.writeFileSync(tmp, text, { mode });
  try { fs.chmodSync(tmp, mode); } catch (_) {}
  if (uid >= 0) { try { fs.chownSync(tmp, uid, gid); } catch (_) {} }
  fs.renameSync(tmp, ENV.configPath);
  return text;
}

/* ------------------------------------------------------------ 系统指标 */

let lastCpu = null;
function cpuPercent() {
  const cpus = os.cpus();
  let idle = 0, total = 0;
  for (const c of cpus) {
    for (const k in c.times) total += c.times[k];
    idle += c.times.idle;
  }
  const snap = { idle, total };
  if (!lastCpu) { lastCpu = snap; return { percent: 0, cores: cpus.length, first: true }; }
  const dIdle = snap.idle - lastCpu.idle;
  const dTotal = snap.total - lastCpu.total;
  lastCpu = snap;
  const pct = dTotal > 0 ? Math.max(0, Math.min(100, 100 * (1 - dIdle / dTotal))) : 0;
  return { percent: +pct.toFixed(1), cores: cpus.length, first: false };
}

async function diskUsage(target = '/') {
  const r = await run('df', ['-B1', '-P', target]);
  if (r.code !== 0) return null;
  const line = r.out.trim().split('\n')[1];
  if (!line) return null;
  const p = line.trim().split(/\s+/);
  const total = parseInt(p[1], 10), used = parseInt(p[2], 10), free = parseInt(p[3], 10);
  return { mount: p[5], total, used, free, percent: total ? +(100 * used / total).toFixed(1) : 0 };
}

let ipCache = { at: 0, ip: '' };
async function exitIp() {
  if (Date.now() - ipCache.at < 60000) return ipCache;
  const urls = [
    'https://api.ipify.org?format=json',
    'https://ipv4.icanhazip.com/',
    'https://ifconfig.me/ip',
  ];
  for (const u of urls) {
    try {
      const ctl = AbortSignal.timeout(6000);
      const res = await fetch(u, { signal: ctl, headers: { 'user-agent': 'curl/8' } });
      if (!res.ok) continue;
      const txt = (await res.text()).trim();
      let ip = txt;
      try { ip = JSON.parse(txt).ip || txt; } catch (_) {}
      if (ip && /^[0-9a-fA-F:.]+$/.test(ip)) { ipCache = { at: Date.now(), ip }; return ipCache; }
    } catch (_) {}
  }
  return ipCache;
}

/* -------------------------------------------------------- sing-box 状态 */

async function serviceState() {
  if (USE_SYSTEMD) {
    const a = await run('systemctl', ['is-active', ENV.service]);
    const s = a.out.trim();
    const pid = await run('systemctl', ['show', '-p', 'MainPID', '--value', ENV.service]);
    let version = '';
    const v = await run(ENV.bin, ['version']);
    if (v.code === 0) version = (v.out.split('\n')[0] || '').trim();
    return {
      mode: 'systemd', unit: ENV.service, state: s || 'unknown',
      running: s === 'active', pid: parseInt(pid.out.trim(), 10) || 0, version,
    };
  }
  // 直管进程
  const pidFile = path.join(os.tmpdir(), 'panel-singbox.pid');
  let pid = 0;
  try {
    pid = parseInt(fs.readFileSync(pidFile, 'utf8').trim(), 10) || 0;
    process.kill(pid, 0);
  } catch (_) { pid = 0; }
  if (!pid) {
    const p = await run('pgrep', ['-f', 'sing[-]box']);
    pid = parseInt((p.out.trim().split('\n')[0] || '0'), 10) || 0;
  }
  let version = '';
  const v = await run(ENV.bin, ['version']);
  if (v.code === 0) version = (v.out.split('\n')[0] || '').trim();
  return { mode: 'process', unit: ENV.service, state: pid ? 'active' : 'inactive', running: !!pid, pid, version };
}

function binAvailable() {
  try { fs.accessSync(ENV.bin, fs.constants.X_OK); return true; } catch (_) {}
  return false;
}

// systemctl 返回 0 不等于 sing-box 接受了配置：等状态稳定后再判定
async function waitActive(ms) {
  const deadline = Date.now() + ms;
  let state = 'unknown';
  for (;;) {
    const r = await run('systemctl', ['is-active', ENV.service]);
    state = r.out.trim();
    if (state === 'active') return { ok: true, state };
    if (Date.now() > deadline) return { ok: false, state };
    await new Promise(s => setTimeout(s, 200));
  }
}

async function control(action) {
  if (USE_SYSTEMD) {
    if (action === 'reload') {
      const r = await run('systemctl', ['reload', ENV.service]);
      if (r.code !== 0) return { ok: false, msg: 'reload 失败: ' + (r.err || r.out).trim() };
      const w = await waitActive(3000);
      if (!w.ok) return { ok: false, msg: 'reload 后服务未回到 active（当前 ' + w.state + '）：sing-box 拒绝了新配置，详见日志' };
      return { ok: true, msg: '已 reload' };
    }
    const r = await run('systemctl', [action, ENV.service]);
    const msg = (r.out + r.err).trim() || (action + ' 完成');
    if (r.code !== 0) return { ok: false, msg };
    if (action === 'stop') return { ok: true, msg: '已停止' };
    const w = await waitActive(6000);
    if (!w.ok) return { ok: false, msg: '命令已执行但服务未进入 active（当前 ' + w.state + '）：检查配置与日志' };
    return { ok: true, msg };
  }
  const state = await serviceState();
  if (action === 'stop') {
    if (state.pid) { try { process.kill(state.pid, 'SIGTERM'); } catch (e) { return { ok: false, msg: e.message }; } }
    return { ok: true, msg: '已停止 (pid ' + state.pid + ')' };
  }
  if (action === 'restart' && state.pid) {
    try { process.kill(state.pid, 'SIGTERM'); } catch (_) {}
    await new Promise(r => setTimeout(r, 800));
  }
  const cfgCheck = await run(ENV.bin, ['check', '-c', ENV.configPath]);
  if (cfgCheck.code !== 0) return { ok: false, msg: '配置检查失败: ' + (cfgCheck.err || cfgCheck.out).trim() };
  const out = fs.openSync(ENV.logFile, 'a');
  const child = spawn(ENV.bin, ['run', '-c', ENV.configPath], { detached: true, stdio: ['ignore', out, out] });
  child.unref();
  fs.writeFileSync(path.join(os.tmpdir(), 'panel-singbox.pid'), String(child.pid));
  await new Promise(r => setTimeout(r, 600));
  const after = await serviceState();
  return { ok: after.running, msg: after.running ? ('已启动 (pid ' + child.pid + ')') : '启动后进程未存活，检查日志' };
}

async function logs(lines = 200) {
  const n = Math.max(1, Math.min(2000, parseInt(lines, 10) || 200));
  if (USE_SYSTEMD) {
    const r = await run('journalctl', ['-u', ENV.service, '-n', String(n), '--no-pager']);
    if (r.code === 0) return r.out;
    return (r.err || '') + '\n(journalctl 不可用)';
  }
  if (!fs.existsSync(ENV.logFile)) return '(暂无日志文件 ' + ENV.logFile + ')';
  const r = await run('tail', ['-n', String(n), ENV.logFile]);
  return r.out || r.err;
}

async function singboxCheck() {
  const r = await run(ENV.bin, ['check', '-c', ENV.configPath]);
  return { ok: r.code === 0, output: (r.out + r.err).trim() };
}

/* --------------------------------------------------------- 链路推导 */

function buildGraph(config) {
  const inbounds = (config.inbounds || []).map(i => ({ tag: i.tag, type: i.type, listen: i.listen || '', port: i.listen_port }));
  const outbounds = (config.outbounds || []).map(o => ({ tag: o.tag, type: o.type, detour: o.detour || '', server: o.server || '', port: o.server_port }));
  const rules = ((config.route && config.route.rules) || []);
  const edges = [];
  for (const r of rules) {
    const ins = r.inbound || [];
    const out = r.outbound;
    if (!out) continue;
    for (const itag of ins) edges.push({ from: itag, to: out, kind: 'route' });
    if (!ins.length && r.outbound) edges.push({ from: '*', to: out, kind: 'default' });
  }
  const dflt = config.route && config.route.final;
  if (dflt) edges.push({ from: '*', to: dflt, kind: 'final' });
  for (const o of outbounds) {
    if (o.detour) edges.push({ from: o.tag, to: o.detour, kind: 'detour' });
  }
  const finalOut = config.route ? config.route.final : undefined;
  const inRule = new Set(), outRule = new Set();
  for (const e of edges) {
    if (e.kind === 'route') { inRule.add(e.from); }
    if (e.kind === 'route' || e.kind === 'final' || e.kind === 'default') outRule.add(e.to);
  }
  return {
    inbounds, outbounds, edges, final: finalOut,
    unbound: inbounds.filter(i => !inRule.has(i.tag)).map(i => i.tag),
    unused: outbounds.filter(o => !outRule.has(o.tag) && !o.detour).map(o => o.tag),
  };
}

function setBind(config, inbound, outbound) {
  config.route = config.route || {};
  config.route.rules = config.route.rules || [];
  const rules = config.route.rules;
  let touched = false;
  for (const r of rules) {
    if (Array.isArray(r.inbound) && r.inbound.includes(inbound)) {
      if (outbound) { r.outbound = outbound; touched = true; }
      else {
        r.inbound = r.inbound.filter(t => t !== inbound);
        if (!r.inbound.length) { delete r.inbound; delete r.outbound; }
        touched = true;
      }
    }
  }
  if (outbound && !touched) rules.push({ inbound: [inbound], outbound });
  // 清掉因删除入站而产生的空规则
  config.route.rules = rules.filter(r => Object.keys(r).length > 0);
  return config;
}

// sing-box 只允许会真正拨号的出站挂 detour；direct/block/组出站挂了会被 FATAL 拒绝
function detourUnsupported(type) {
  return ['direct', 'block', 'dns', 'selector', 'urltest'].includes(type);
}

function setDetour(config, outboundTag, detourTag) {
  const list = config.outbounds || [];
  const o = list.find(x => x.tag === outboundTag);
  if (!o) throw new Error('找不到出站: ' + outboundTag);
  if (detourTag) {
    if (detourUnsupported(o.type)) {
      throw new Error(o.type + ' 类型出站不支持链式：sing-box 会直接 FATAL（detour is not supported in direct context）；' +
        '只有真正拨号的出站（vless / trojan / shadowsocks / socks / hysteria2 等）才能挂 detour');
    }
    if (detourTag === outboundTag) throw new Error('链路不能指向自己');
    if (!list.some(x => x.tag === detourTag)) throw new Error('找不到出站: ' + detourTag);
    // 防环
    let cur = detourTag, guard = 0;
    while (cur && guard++ < 50) {
      if (cur === outboundTag) throw new Error('会形成环路：' + outboundTag + ' → ' + detourTag);
      const nxt = list.find(x => x.tag === cur);
      cur = nxt && nxt.detour;
    }
    o.detour = detourTag;
  } else {
    delete o.detour;
  }
  return config;
}

/* ------------------------------------------------------------- HTTP */

async function withCheck(obj) {
  if (binAvailable()) {
    const c = await singboxCheck();
    obj.check = { ok: c.ok, output: c.output || '(无输出)' };
  }
  return obj;
}


/* ------------------------------------------------------------ 证书辅助 */

const CERT_DIR = process.env.SINGBOX_CERT_DIR || path.join(path.dirname(ENV.configPath), 'certs');

function looksLikeKey(p) {
  try {
    const fd = fs.openSync(p, 'r');
    const buf = Buffer.alloc(256);
    const n = fs.readSync(fd, buf, 0, 256, 0);
    fs.closeSync(fd);
    return buf.slice(0, n).toString().includes('PRIVATE KEY');
  } catch (_) { return false; }
}

function listCerts() {
  const res = { dir: CERT_DIR, exists: false, certs: [], keys: [], pairs: [] };
  let entries;
  try {
    if (!fs.statSync(CERT_DIR).isDirectory()) return res;
    entries = fs.readdirSync(CERT_DIR);
  } catch (_) { return res; }
  res.exists = true;
  for (const name of entries) {
    const p = path.join(CERT_DIR, name);
    try { if (fs.statSync(p).isDirectory()) continue; } catch (_) { continue; }
    const ext = path.extname(name).toLowerCase();
    if (ext === '.key') res.keys.push(p);
    else if (ext === '.crt' || ext === '.cer') res.certs.push(p);
    else if (ext === '.pem') (looksLikeKey(p) ? res.keys : res.certs).push(p);
  }
  res.certs.sort(); res.keys.sort();
  for (const c of res.certs) {
    const base = path.basename(c, path.extname(c));
    for (const k of res.keys) {
      const kb = path.basename(k, path.extname(k));
      if (kb === base || base.startsWith(kb) || kb.startsWith(base)) {
        res.pairs.push({ name: base, cert: c, key: k });
        break;
      }
    }
  }
  return res;
}

function certSafeName(name, domain) {
  let n = (name || domain || 'self-signed').trim();
  n = n.replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 64);
  return n || 'self-signed';
}

async function makeSelfSigned(domain, name) {
  domain = (domain || '').trim() || 'localhost';
  fs.mkdirSync(CERT_DIR, { recursive: true, mode: 0o700 });
  const base = certSafeName(name, domain);
  const cert = path.join(CERT_DIR, base + '.crt');
  const key = path.join(CERT_DIR, base + '.key');
  if (fs.existsSync(cert)) throw new Error('同名证书已存在: ' + cert);
  const r = await run('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
    '-nodes', '-days', '3650', '-keyout', key, '-out', cert,
    '-subj', '/CN=' + domain, '-addext', 'subjectAltName=DNS:' + domain]);
  if (r.code !== 0) throw new Error('openssl 生成失败: ' + (r.err || r.out).trim());
  try { fs.chmodSync(key, 0o600); fs.chmodSync(cert, 0o644); } catch (_) {}
  return { ok: true, certificate_path: cert, key_path: key, dir: CERT_DIR, domain, msg: '已生成自签证书（有效期 10 年）' };
}

async function genRealityKeypair() {
  if (!binAvailable()) throw new Error('找不到 sing-box（' + ENV.bin + '），无法生成密钥');
  const r = await run(ENV.bin, ['generate', 'reality-keypair']);
  if (r.code !== 0) throw new Error('生成失败: ' + (r.err || r.out).trim());
  let priv = '', pub = '';
  for (const line of r.out.split('\n')) {
    const t = line.trim();
    if (t.startsWith('PrivateKey:')) priv = t.slice(11).trim();
    if (t.startsWith('PublicKey:')) pub = t.slice(10).trim();
  }
  if (!priv || !pub) throw new Error('解析密钥失败: ' + r.out.trim());
  return { ok: true, private_key: priv, public_key: pub, msg: '已生成 Reality 密钥对\n公钥（填到客户端）: ' + pub };
}

function saveCertFiles(name, certPEM, keyPEM) {
  certPEM = (certPEM || '').trim(); keyPEM = (keyPEM || '').trim();
  if (!certPEM.includes('BEGIN CERTIFICATE')) throw new Error('证书内容不对：没找到 BEGIN CERTIFICATE（请粘贴完整的 PEM 文本）');
  if (!keyPEM.includes('PRIVATE KEY')) throw new Error('私钥内容不对：没找到 PRIVATE KEY（请粘贴完整的 PEM 文本）');
  fs.mkdirSync(CERT_DIR, { recursive: true, mode: 0o700 });
  const base = certSafeName(name, '');
  const cert = path.join(CERT_DIR, base + '.crt');
  const key = path.join(CERT_DIR, base + '.key');
  fs.writeFileSync(cert, certPEM + '\n', { mode: 0o644 });
  fs.writeFileSync(key, keyPEM + '\n', { mode: 0o600 });
  return { ok: true, certificate_path: cert, key_path: key, dir: CERT_DIR, msg: '证书已保存' };
}

/* ------------------------------------------------------------ 认证 */
// 两种凭据来源：环境变量 PANEL_USER/PANEL_PASSWORD，或凭据文件（PBKDF2-SHA256 加盐哈希，0600）。
// 都没有时进入「首次设置」流程，只开放设置页。用户名同样校验。

const crypto = require('crypto');
const AUTH_FILE = process.env.PANEL_AUTH_FILE || '/etc/sbpanel-auth.json';
const PBKDF2_ITER = 120000;
const authCache = new Map();

function envUser() { return (process.env.PANEL_USER || '').trim() || 'admin'; }

function loadAuthFile() {
  try {
    const af = JSON.parse(fs.readFileSync(AUTH_FILE, 'utf8'));
    if (!af.user || !af.salt || !af.hash) return null;
    if (!af.iter) af.iter = PBKDF2_ITER;
    return af;
  } catch (_) { return null; }
}

function authConfigured() { return !!process.env.PANEL_PASSWORD || !!loadAuthFile(); }

function derive(pass, saltB64, iter) {
  return crypto.pbkdf2Sync(Buffer.from(pass, 'utf8'), Buffer.from(saltB64, 'base64'), iter || PBKDF2_ITER, 32, 'sha256');
}

function verifyCredentials(user, pass) {
  if (!user && !pass) return false;
  // 凭据文件优先（面板里改过的存在这里），没有文件时才用环境变量
  const af = loadAuthFile();
  if (!af) {
    const envPass = process.env.PANEL_PASSWORD || '';
    if (!envPass) return false;
    const a = Buffer.from(String(pass)), b = Buffer.from(envPass);
    return user === envUser() && a.length === b.length && crypto.timingSafeEqual(a, b);
  }
  if (user !== af.user) return false;
  const got = derive(String(pass), af.salt, af.iter);
  const want = Buffer.from(af.hash, 'base64');
  return got.length === want.length && crypto.timingSafeEqual(got, want);
}

function verifyCached(user, pass) {
  const key = crypto.createHash('sha256').update(user + '\u0000' + pass).digest('hex');
  if (authCache.has(key)) return authCache.get(key);
  const ok = verifyCredentials(user, pass);
  if (ok) { if (authCache.size > 32) authCache.clear(); authCache.set(key, true); }
  return ok;
}

function saveCredentials(user, password) {
  user = String(user || '').trim(); password = String(password || '').trim();
  if (user.length < 2 || user.length > 64) throw new Error('用户名长度要在 2-64 之间');
  if (password.length < 6) throw new Error('密码至少 6 位（建议 10 位以上）');
  const salt = crypto.randomBytes(16);
  const hash = derive(password, salt.toString('base64'), PBKDF2_ITER);
  const af = { user, algo: 'pbkdf2-sha256', iter: PBKDF2_ITER,
    salt: salt.toString('base64'), hash: hash.toString('base64') };
  fs.mkdirSync(path.dirname(AUTH_FILE), { recursive: true, mode: 0o700 });
  const tmp = AUTH_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(af, null, 2) + '\n', { mode: 0o600 });
  fs.chmodSync(tmp, 0o600);
  fs.renameSync(tmp, AUTH_FILE);
  authCache.clear();
}

const ENV_FILE = process.env.PANEL_ENV_FILE || '/etc/sbpanel.env';

function syncEnvFile(user, pass) {
  let txt;
  try { txt = fs.readFileSync(ENV_FILE, 'utf8'); } catch (_) { return; }
  const lines = txt.replace(/\n$/, '').split('\n');
  let seenU = false, seenP = false;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('PANEL_USER=')) { lines[i] = 'PANEL_USER=' + user; seenU = true; }
    else if (lines[i].startsWith('PANEL_PASSWORD=')) { lines[i] = 'PANEL_PASSWORD=' + pass; seenP = true; }
  }
  if (!seenU) lines.push('PANEL_USER=' + user);
  if (!seenP) lines.push('PANEL_PASSWORD=' + pass);
  const tmp = ENV_FILE + '.tmp';
  fs.writeFileSync(tmp, lines.join('\n') + '\n', { mode: 0o600 });
  try { fs.chmodSync(tmp, 0o600); } catch (_) {}
  fs.renameSync(tmp, ENV_FILE);
}

function changeCredentials(oldPass, user, password) {
  if (!authConfigured()) throw new Error('尚未配置凭据');
  const af = loadAuthFile();
  const cur = af ? af.user : envUser();
  if (!verifyCredentials(cur, oldPass)) throw new Error('当前密码不正确');
  saveCredentials(user, password);
  try { syncEnvFile(user, password); }
  catch (e) { throw new Error('账号已生效，但写回 ' + ENV_FILE + ' 失败（重启后会回到旧账号）: ' + e.message); }
}

function listBackups() {
  const dir = path.dirname(ENV.configPath), base = path.basename(ENV.configPath);
  const res = { dir, config: ENV.configPath, files: [] };
  let entries = [];
  try { entries = fs.readdirSync(dir); } catch (_) { return res; }
  for (const name of entries) {
    if (!name.startsWith(base + '.bak.')) continue;
    try { const st = fs.statSync(path.join(dir, name));
      res.files.push({ name, size: st.size, mtime: st.mtime.toISOString().slice(0, 19).replace('T', ' ') });
    } catch (_) {}
  }
  res.files.sort((a, b) => (a.name < b.name ? 1 : -1));
  res.count = res.files.length;
  return res;
}

function restoreBackup(name) {
  const dir = path.dirname(ENV.configPath), base = path.basename(ENV.configPath);
  name = String(name || '').trim();
  if (!name || name.includes('/') || name.includes('..') || !name.startsWith(base + '.bak.'))
    throw new Error('备份文件名不合法');
  const raw = fs.readFileSync(path.join(dir, name), 'utf8');
  let cfg; try { cfg = JSON.parse(raw); } catch (e) { throw new Error('备份内容不是合法 JSON: ' + e.message); }
  writeConfigAtomic(cfg);
  return { ok: true, msg: '已从备份恢复（当前配置已另存为新的备份）', file: name, graph: buildGraph(cfg) };
}

function send(res, code, body, headers = {}) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers });
  res.end(buf);
}

function basicCreds(req) {
  const h = req.headers['authorization'] || '';
  if (!h.startsWith('Basic ')) return null;
  const dec = Buffer.from(h.slice(6), 'base64').toString('utf8');
  const idx = dec.indexOf(':');
  if (idx < 0) return null;
  return { user: dec.slice(0, idx), pass: dec.slice(idx + 1) };
}

// 用户名 + 密码都要对；未配置凭据时交给首次设置流程
function authed(req) {
  if (!authConfigured()) return false;
  const c = basicCreds(req);
  if (!c) return false;
  return verifyCached(c.user, c.pass);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '', size = 0;
    req.on('data', c => {
      size += c.length;
      if (size > 16 * 1024 * 1024) { reject(new Error('请求体过大')); req.destroy(); return; }
      data += c;
    });
    req.on('end', () => {
      if (!data) return resolve({});
      try { resolve(JSON.parse(data)); } catch (e) { reject(new Error('请求体不是合法 JSON')); }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://' + (req.headers.host || 'localhost'));
  const p = url.pathname;

  // 还没配置任何凭据 → 只提供首次设置页
  if (!authConfigured()) {
    if (p === '/setup' || p === '/') {
      try {
        const html = fs.readFileSync(path.join(__dirname, 'setup.html'), 'utf8');
        return send(res, 200, html, { 'content-type': 'text/html; charset=utf-8' });
      } catch (e) { return send(res, 500, { error: e.message }); }
    }
    if (p === '/api/setup' && req.method === 'POST') {
      const b = await readBody(req);
      try { saveCredentials(b.user, b.password); return send(res, 200, { ok: true, msg: '账号已设置' }); }
      catch (e) { return send(res, 400, { ok: false, error: e.message }); }
    }
    if (p === '/api/auth/state') {
      return send(res, 200, { configured: false, setup_required: true, setup_url: '/setup' });
    }
    return send(res, 401, { error: '面板还没设置账号', setup_required: true, setup_url: '/setup' });
  }

  if (!authed(req)) {
    return send(res, 401, { error: '用户名或密码不正确' }, { 'www-authenticate': 'Basic realm="sbpanel"' });
  }

  try {
    if (p === '/' || p === '/index.html') {
      const html = fs.readFileSync(UI_FILE, 'utf8');
      return send(res, 200, html, { 'content-type': 'text/html; charset=utf-8' });
    }

    if (p === '/api/status' && req.method === 'GET') {
      const [disk, ip, svc] = await Promise.all([diskUsage('/'), exitIp(), serviceState()]);
      const cpu = cpuPercent();
      const mem = { total: os.totalmem(), free: os.freemem() };
      mem.used = mem.total - mem.free;
      mem.percent = +(100 * mem.used / mem.total).toFixed(1);
      const cfg = readConfig();
      return send(res, 200, {
        cpu, mem, disk,
        exitIp: ip.ip || '',
        ipCheckedAt: ip.at,
        loadavg: os.loadavg(),
        uptime: os.uptime(),
        hostname: os.hostname(),
        platform: os.platform() + ' ' + os.arch(),
        service: svc,
        config: { path: ENV.configPath, exists: fs.existsSync(ENV.configPath), valid: cfg.ok, error: cfg.ok ? '' : cfg.error },
        now: Date.now(),
      });
    }

    if (p === '/api/config' && req.method === 'GET') {
      const cfg = readConfig();
      if (!cfg.ok) return send(res, 200, { ok: false, error: cfg.error, raw: cfg.raw, graph: null });
      return send(res, 200, { ok: true, raw: cfg.raw, config: cfg.config, graph: buildGraph(cfg.config) });
    }

    if (p === '/api/config' && req.method === 'PUT') {
      const body = await readBody(req);
      let obj;
      if (typeof body.raw === 'string') {
        try { obj = JSON.parse(body.raw); } catch (e) { return send(res, 400, { ok: false, error: 'JSON 解析失败: ' + e.message }); }
      } else if (body.config && typeof body.config === 'object') {
        obj = body.config;
      } else return send(res, 400, { ok: false, error: '缺少 raw 或 config' });
      writeConfigAtomic(obj);
      return send(res, 200, await withCheck({ ok: true, msg: '已保存', graph: buildGraph(obj) }));
    }

    if (p === '/api/config/check' && req.method === 'POST') {
      return send(res, 200, await singboxCheck());
    }

    if (p === '/api/bind' && req.method === 'POST') {
      const b = await readBody(req);
      const cfg = readConfig();
      if (!cfg.ok) return send(res, 400, { ok: false, error: cfg.error });
      setBind(cfg.config, b.inbound, b.outbound || null);
      writeConfigAtomic(cfg.config);
      return send(res, 200, await withCheck({ ok: true, graph: buildGraph(cfg.config) }));
    }

    if (p === '/api/chain' && req.method === 'POST') {
      const b = await readBody(req);
      const cfg = readConfig();
      if (!cfg.ok) return send(res, 400, { ok: false, error: cfg.error });
      try { setDetour(cfg.config, b.outbound, b.detour || null); }
      catch (e) { return send(res, 400, { ok: false, error: e.message }); }
      writeConfigAtomic(cfg.config);
      return send(res, 200, await withCheck({ ok: true, graph: buildGraph(cfg.config) }));
    }

    if (p === '/api/object' && req.method === 'POST') {
      const b = await readBody(req);       // {kind:'inbound'|'outbound', original:tag|null, data:{...}}
      const cfg = readConfig();
      if (!cfg.ok) return send(res, 400, { ok: false, error: cfg.error });
      const key = b.kind === 'inbound' ? 'inbounds' : 'outbounds';
      const list = cfg.config[key] = cfg.config[key] || [];
      if (!b.data || typeof b.data !== 'object') return send(res, 400, { ok: false, error: '缺少 data' });
      if (!b.data.tag) return send(res, 400, { ok: false, error: '必须填写 tag' });
      const i = list.findIndex(x => x.tag === b.original);
      if (i >= 0) list[i] = b.data; else list.push(b.data);
      try { writeConfigAtomic(cfg.config); } catch (e) { return send(res, 400, { ok: false, error: e.message }); }
      return send(res, 200, await withCheck({ ok: true, graph: buildGraph(cfg.config) }));
    }

    if (p === '/api/object' && req.method === 'DELETE') {
      const kind = url.searchParams.get('kind');
      const tag = url.searchParams.get('tag');
      const cfg = readConfig();
      if (!cfg.ok) return send(res, 400, { ok: false, error: cfg.error });
      const key = kind === 'inbound' ? 'inbounds' : 'outbounds';
      cfg.config[key] = (cfg.config[key] || []).filter(x => x.tag !== tag);
      if (kind === 'outbound') {
        for (const o of cfg.config.outbounds || []) if (o.detour === tag) delete o.detour;
        const route = cfg.config.route || (cfg.config.route = {});
        const rules = (route.rules = route.rules || []);
        route.rules = rules.filter(r => r.outbound !== tag);
        if (route.final === tag) {
          const rest = (cfg.config.outbounds || [])[0];
          if (rest) route.final = rest.tag; else delete route.final;
        }
      } else {
        for (const r of (cfg.config.route && cfg.config.route.rules) || []) {
          if (Array.isArray(r.inbound)) r.inbound = r.inbound.filter(t => t !== tag);
        }
        if (cfg.config.route) cfg.config.route.rules = (cfg.config.route.rules || []).filter(r => !(r.inbound && !r.inbound.length));
      }
      writeConfigAtomic(cfg.config);
      return send(res, 200, { ok: true, graph: buildGraph(cfg.config) });
    }

    if (p === '/api/service' && req.method === 'POST') {
      const b = await readBody(req);
      const act = b.action;
      if (!['start', 'stop', 'restart', 'reload'].includes(act)) return send(res, 400, { ok: false, error: '不支持的动作' });
      if (act === 'start' || act === 'restart' || act === 'reload') {
        const cfg = readConfig();
        if (!cfg.ok) return send(res, 400, { ok: false, error: '配置无效，拒绝启动: ' + cfg.error });
        // JSON 合法 ≠ sing-box 接受
        if (binAvailable()) {
          const chk = await singboxCheck();
          if (!chk.ok) return send(res, 400, { ok: false, error: 'sing-box 拒绝该配置，已取消操作: ' + chk.output });
        }
      }
      const r = await control(act);
      return send(res, r.ok ? 200 : 400, r);
    }

    if (p === '/api/logs' && req.method === 'GET') {
      const txt = await logs(url.searchParams.get('lines') || 200);
      return send(res, 200, { ok: true, log: txt });
    }


    if (p === '/api/auth/state' && req.method === 'GET') {
      let user = envUser(), source = 'env';
      const af = loadAuthFile();
      if (af) { user = af.user; source = 'file'; }
      return send(res, 200, { configured: true, user, source, can_change: true, auth_file: AUTH_FILE, env_file: ENV_FILE });
    }

    if (p === '/api/auth/change' && req.method === 'POST') {
      const b = await readBody(req);
      try { changeCredentials(b.old_password, b.user, b.password); return send(res, 200, { ok: true, msg: '账号已更新，请用新账号重新登录' }); }
      catch (e) { return send(res, 400, { ok: false, error: e.message }); }
    }

    if (p === '/api/backups' && req.method === 'GET') {
      return send(res, 200, listBackups());
    }

    if (p === '/api/config/restore' && req.method === 'POST') {
      const b = await readBody(req);
      try { return send(res, 200, restoreBackup(b.file)); }
      catch (e) { return send(res, 400, { ok: false, error: e.message }); }
    }

    if (p === '/api/gen/reality' && req.method === 'POST') {
      try { return send(res, 200, await genRealityKeypair()); }
      catch (e) { return send(res, 400, { ok: false, error: e.message }); }
    }

    if (p === '/api/certs' && req.method === 'GET') {
      return send(res, 200, listCerts());
    }

    if (p === '/api/certs/selfsigned' && req.method === 'POST') {
      const b = await readBody(req);
      try { return send(res, 200, await makeSelfSigned(b.domain, b.name)); }
      catch (e) { return send(res, 400, { ok: false, error: e.message }); }
    }

    if (p === '/api/certs/upload' && req.method === 'POST') {
      const b = await readBody(req);
      try { return send(res, 200, saveCertFiles(b.name, b.cert, b.key)); }
      catch (e) { return send(res, 400, { ok: false, error: e.message }); }
    }

    if (p === '/api/export' && req.method === 'GET') {
      const raw = readConfigRaw();
      return send(res, raw.ok ? 200 : 404, raw.raw || '配置文件不存在', {
        'content-type': 'application/json; charset=utf-8',
        'content-disposition': 'attachment; filename="config.json"',
      });
    }

    return send(res, 404, { error: 'not found' });
  } catch (e) {
    return send(res, 500, { ok: false, error: e.message });
  }
});

server.listen(ENV.port, ENV.host, () => {
  console.log(`sing-box 面板已启动: http://${ENV.host}:${ENV.port}`);
  console.log(`  配置: ${ENV.configPath}`);
  console.log(`  控制: ${USE_SYSTEMD ? 'systemd ' + ENV.service : '直接进程 (' + ENV.bin + ')'}`);
  console.log(`  登录: ${ENV.password ? '已启用' : '未启用 (设置 PANEL_PASSWORD 开启)'}`);
});

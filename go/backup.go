package main

// 配置备份 / 恢复：面板每次保存都会在同目录留下 config.json.bak.<时间戳>，
// 这里把它们列出来，并支持一键恢复（恢复前同样会先备份当前配置）。
// 导入功能走 PUT /api/config（前端选本地文件后读成文本提交），逻辑与保存一致。

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func listBackups() map[string]any {
	dir := filepath.Dir(E.ConfigPath)
	base := filepath.Base(E.ConfigPath)
	res := map[string]any{"dir": dir, "config": E.ConfigPath, "files": []map[string]any{}}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return res
	}
	files := []map[string]any{}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, base+".bak.") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		files = append(files, map[string]any{
			"name":  name,
			"size":  info.Size(),
			"mtime": info.ModTime().Format("2006-01-02 15:04:05"),
		})
	}
	// 文件名内含时间戳，倒序即最新在前
	sort.Slice(files, func(i, j int) bool {
		return files[i]["name"].(string) > files[j]["name"].(string)
	})
	res["files"] = files
	res["count"] = len(files)
	return res
}

func restoreBackup(name string) (map[string]any, error) {
	dir := filepath.Dir(E.ConfigPath)
	base := filepath.Base(E.ConfigPath)
	name = strings.TrimSpace(name)
	if name == "" || strings.Contains(name, "/") || strings.Contains(name, "..") ||
		!strings.HasPrefix(name, base+".bak.") {
		return nil, fmt.Errorf("备份文件名不合法")
	}
	raw, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return nil, fmt.Errorf("读取备份失败: %v", err)
	}
	v, err := parseJSON(raw)
	if err != nil {
		return nil, fmt.Errorf("备份内容不是合法 JSON: %v", err)
	}
	cfg, ok := v.(*omap)
	if !ok {
		return nil, fmt.Errorf("备份根节点必须是对象")
	}
	if err := writeConfig(cfg); err != nil { // 会先把当前配置再备份一次
		return nil, err
	}
	return map[string]any{
		"ok": true, "msg": "已从备份恢复（当前配置已另存为新的备份）",
		"file": name, "graph": buildGraph(cfg),
	}, nil
}

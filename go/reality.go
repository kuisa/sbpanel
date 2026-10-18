package main

import (
	"crypto/ecdh"
	"encoding/base64"
	"fmt"
	"strings"
)

// deriveRealityPublicKey 从服务端私钥推导 Reality 公钥。
// 服务端配置里只存私钥，客户端要的 public_key 由私钥唯一确定（X25519）。
func deriveRealityPublicKey(privB64 string) (string, error) {
	privB64 = strings.TrimSpace(privB64)
	if privB64 == "" {
		return "", fmt.Errorf("私钥为空")
	}
	// sing-box 用的是 base64 RawURLEncoding（无填充）
	b, err := base64.RawURLEncoding.DecodeString(privB64)
	if err != nil {
		// 兼容带填充的标准 base64
		if b2, e2 := base64.StdEncoding.DecodeString(privB64); e2 == nil {
			b, err = b2, nil
		}
	}
	if err != nil {
		return "", fmt.Errorf("私钥不是合法 base64: %v", err)
	}
	if len(b) != 32 {
		return "", fmt.Errorf("私钥长度应为 32 字节，实际 %d", len(b))
	}
	k, err := ecdh.X25519().NewPrivateKey(b)
	if err != nil {
		return "", fmt.Errorf("私钥无效: %v", err)
	}
	return base64.RawURLEncoding.EncodeToString(k.PublicKey().Bytes()), nil
}

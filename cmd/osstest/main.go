// osstest verifies that the Alibaba Cloud OSS SDK can connect, upload, list,
// download, and delete objects using credentials from
// ~/.openvpn-bootstrap/credentials.json (the operator's machine) or
// /root/.ossutilconfig (inside the container).
//
// Usage:
//
//	go run ./cmd/osstest
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/aliyun/aliyun-oss-go-sdk/oss"
)

type creds struct {
	OSSAccessKeyID     string `json:"oss_access_key_id"`
	OSSAccessKeySecret string `json:"oss_access_key_secret"`
	OSSBucket          string `json:"oss_bucket"`
	OSSEndpoint        string `json:"oss_endpoint"`
}

func loadFromCredJSON() (creds, error) {
	home, _ := os.UserHomeDir()
	path := filepath.Join(home, ".openvpn-bootstrap", "credentials.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return creds{}, fmt.Errorf("cannot read %s: %w", path, err)
	}
	var c creds
	if err := json.Unmarshal(data, &c); err != nil {
		return creds{}, fmt.Errorf("cannot parse %s: %w", path, err)
	}
	return c, nil
}

func loadFromOSSUtilConfig() (creds, error) {
	const path = "/root/.ossutilconfig"
	data, err := os.ReadFile(path)
	if err != nil {
		return creds{}, fmt.Errorf("cannot read %s: %w", path, err)
	}
	var c creds
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch strings.TrimSpace(k) {
		case "accessKeyID":
			c.OSSAccessKeyID = strings.TrimSpace(v)
		case "accessKeySecret":
			c.OSSAccessKeySecret = strings.TrimSpace(v)
		case "endpoint":
			c.OSSEndpoint = strings.TrimSpace(v)
		}
	}
	return c, nil
}

func main() {
	var c creds
	var err error

	// Try the operator's machine file first, fall back to container config.
	c, err = loadFromCredJSON()
	if err != nil {
		fmt.Println("[WARN]", err)
		c, err = loadFromOSSUtilConfig()
		if err != nil {
			fmt.Println("[ERROR] Cannot load credentials:", err)
			os.Exit(1)
		}
		fmt.Println("[INFO] Using /root/.ossutilconfig")
	} else {
		fmt.Println("[INFO] Using ~/.openvpn-bootstrap/credentials.json")
	}

	// Override bucket/endpoint from env if provided.
	if v := os.Getenv("OSS_BUCKET"); v != "" {
		c.OSSBucket = v
	}
	if v := os.Getenv("OSS_ENDPOINT"); v != "" {
		c.OSSEndpoint = v
	}

	if c.OSSAccessKeyID == "" || c.OSSAccessKeySecret == "" {
		fmt.Println("[ERROR] OSS credentials are empty.")
		os.Exit(1)
	}
	if c.OSSBucket == "" {
		fmt.Println("[ERROR] OSS bucket is not set.")
		os.Exit(1)
	}

	ep := c.OSSEndpoint
	if !strings.HasPrefix(ep, "http") {
		ep = "https://" + ep
	}

	fmt.Printf("[INFO] Endpoint : %s\n", ep)
	fmt.Printf("[INFO] Bucket   : %s\n", c.OSSBucket)
	fmt.Printf("[INFO] AK ID    : %s...\n", c.OSSAccessKeyID[:8])

	client, err := oss.New(ep, c.OSSAccessKeyID, c.OSSAccessKeySecret)
	if err != nil {
		fmt.Println("[ERROR] oss.New:", err)
		os.Exit(1)
	}

	bucket, err := client.Bucket(c.OSSBucket)
	if err != nil {
		fmt.Println("[ERROR] client.Bucket:", err)
		os.Exit(1)
	}

	// --- Upload ---
	key := fmt.Sprintf("_osstest-%d.txt", time.Now().UnixNano())
	content := fmt.Sprintf("osstest payload at %s", time.Now().UTC())
	fmt.Printf("\n[TEST] Uploading '%s'...\n", key)
	if err := bucket.PutObject(key, strings.NewReader(content)); err != nil {
		fmt.Println("[FAIL] PutObject:", err)
		os.Exit(1)
	}
	fmt.Println("[PASS] Upload OK")

	// --- List ---
	fmt.Println("[TEST] Listing objects (prefix _osstest-)...")
	result, err := bucket.ListObjects(oss.Prefix("_osstest-"), oss.MaxKeys(10))
	if err != nil {
		fmt.Println("[FAIL] ListObjects:", err)
		os.Exit(1)
	}
	found := false
	for _, obj := range result.Objects {
		if obj.Key == key {
			found = true
		}
		fmt.Printf("       • %s  (%d bytes)\n", obj.Key, obj.Size)
	}
	if !found {
		fmt.Printf("[FAIL] '%s' not found in listing\n", key)
		os.Exit(1)
	}
	fmt.Println("[PASS] List OK")

	// --- Download ---
	fmt.Println("[TEST] Downloading object...")
	body, err := bucket.GetObject(key)
	if err != nil {
		fmt.Println("[FAIL] GetObject:", err)
		os.Exit(1)
	}
	defer body.Close()

	buf := new(bytes.Buffer)
	_, _ = buf.ReadFrom(body)
	got := buf.String()
	if got != content {
		fmt.Printf("[FAIL] Content mismatch.\n  want: %q\n  got:  %q\n", content, got)
		os.Exit(1)
	}
	fmt.Println("[PASS] Download OK — content matches")

	// --- Delete ---
	fmt.Printf("[TEST] Deleting '%s'...\n", key)
	if err := bucket.DeleteObject(key); err != nil {
		fmt.Println("[FAIL] DeleteObject:", err)
		os.Exit(1)
	}
	fmt.Println("[PASS] Delete OK")

	fmt.Println("\n[OK] All OSS SDK tests passed.")
}

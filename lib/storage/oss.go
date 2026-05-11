package storage

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path"
	"sort"
	"strings"

	"github.com/aliyun/aliyun-oss-go-sdk/oss"
)

type ossBackend struct {
	bucket   string
	endpoint string
}

func newOSS(bucket, endpoint string) *ossBackend {
	return &ossBackend{bucket: bucket, endpoint: endpoint}
}

// loadOSSCredentials parses /root/.ossutilconfig (mounted into the container)
// and returns the access key ID and secret.
func loadOSSCredentials() (akid, akSecret string, err error) {
	const configPath = "/root/.ossutilconfig"
	f, err := os.Open(configPath)
	if err != nil {
		return "", "", fmt.Errorf("cannot open %s: %w", configPath, err)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if k, v, ok := strings.Cut(line, "="); ok {
			switch strings.TrimSpace(k) {
			case "accessKeyID":
				akid = strings.TrimSpace(v)
			case "accessKeySecret":
				akSecret = strings.TrimSpace(v)
			}
		}
	}
	if akid == "" || akSecret == "" {
		return "", "", fmt.Errorf("accessKeyID/accessKeySecret not found in %s", configPath)
	}
	return akid, akSecret, nil
}

func (o *ossBackend) client() (*oss.Bucket, error) {
	akid, akSecret, err := loadOSSCredentials()
	if err != nil {
		return nil, err
	}
	ep := o.endpoint
	if !strings.HasPrefix(ep, "http") {
		ep = "https://" + ep
	}
	c, err := oss.New(ep, akid, akSecret)
	if err != nil {
		return nil, err
	}
	bkt, err := c.Bucket(o.bucket)
	if err != nil {
		return nil, fmt.Errorf("oss bucket: %w", err)
	}
	return bkt, nil
}

func (o *ossBackend) List(_ context.Context, prefix string) ([]string, error) {
	bkt, err := o.client()
	if err != nil {
		return nil, err
	}
	result, err := bkt.ListObjects(oss.Prefix(prefix), oss.MaxKeys(1000))
	if err != nil {
		return nil, fmt.Errorf("oss list: %w", err)
	}
	var files []string
	for _, obj := range result.Objects {
		name := path.Base(obj.Key)
		if strings.HasSuffix(name, ".log.gz") {
			files = append(files, name)
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(files)))
	return files, nil
}

func (o *ossBackend) Download(_ context.Context, key, localDir string) (string, func(), error) {
	bkt, err := o.client()
	if err != nil {
		return "", func() {}, err
	}
	dest := localDir + "/" + key
	if err := bkt.GetObjectToFile(key, dest); err != nil {
		return "", func() {}, fmt.Errorf("oss download %s: %w", key, err)
	}
	cleanup := func() { _ = os.Remove(dest) }
	return dest, cleanup, nil
}

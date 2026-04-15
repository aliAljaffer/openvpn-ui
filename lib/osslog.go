package lib

import (
	"bufio"
	"fmt"
	"os"
	"path"
	"sort"
	"strings"

	"github.com/aliyun/aliyun-oss-go-sdk/oss"
)

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

func ossClient(endpoint string) (*oss.Client, error) {
	akid, akSecret, err := loadOSSCredentials()
	if err != nil {
		return nil, err
	}
	ep := endpoint
	if !strings.HasPrefix(ep, "http") {
		ep = "https://" + ep
	}
	return oss.New(ep, akid, akSecret)
}

// ListOSSArchives returns filenames of log archives stored in the OSS bucket,
// sorted newest-first. Credentials are read from /root/.ossutilconfig.
func ListOSSArchives(bucket, endpoint string) ([]string, error) {
	client, err := ossClient(endpoint)
	if err != nil {
		return nil, err
	}
	bkt, err := client.Bucket(bucket)
	if err != nil {
		return nil, fmt.Errorf("oss bucket: %w", err)
	}
	result, err := bkt.ListObjects(oss.Prefix("openvpn-logs-"), oss.MaxKeys(1000))
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

// DownloadOSSArchive fetches a named archive from OSS into localDir
// and returns the full local path. Credentials are read from /root/.ossutilconfig.
func DownloadOSSArchive(bucket, endpoint, filename, localDir string) (string, error) {
	client, err := ossClient(endpoint)
	if err != nil {
		return "", err
	}
	bkt, err := client.Bucket(bucket)
	if err != nil {
		return "", fmt.Errorf("oss bucket: %w", err)
	}
	dest := localDir + "/" + filename
	if err := bkt.GetObjectToFile(filename, dest); err != nil {
		return "", fmt.Errorf("oss download %s: %w", filename, err)
	}
	return dest, nil
}

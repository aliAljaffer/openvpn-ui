// Package storage provides a pluggable backend for the openvpn-ui audit log
// archive store. The web UI lists and downloads gzipped log archives through
// this interface; the host-side rotation script writes them via per-provider
// CLI tools (ossutil, aws, gcloud), so this interface is read-only.
package storage

import (
	"context"
	"fmt"
	"strings"

	"github.com/beego/beego/v2/server/web"
)

// Backend is the read-only contract used by the audit log browser.
type Backend interface {
	// List returns archive filenames matching prefix, sorted newest-first.
	List(ctx context.Context, prefix string) ([]string, error)

	// Download fetches the archive named key. For cloud backends, the file is
	// copied into localDir and cleanup() removes that copy. For the local
	// backend, the returned path points at the original archive on disk and
	// cleanup() is a no-op.
	Download(ctx context.Context, key, localDir string) (path string, cleanup func(), err error)
}

// New returns the configured backend.
//
// Selection rules (highest priority first):
//  1. StorageProvider in app.conf, if set to one of: local, oss, s3, gcs
//  2. Backwards-compatible: if OSSLogBucket is set and StorageProvider is empty,
//     default to oss so existing deployments keep working after upgrade.
//  3. Otherwise, default to local.
func New() (Backend, error) {
	provider, _ := web.AppConfig.String("StorageProvider")
	provider = strings.ToLower(strings.TrimSpace(provider))

	if provider == "" {
		if bucket, _ := web.AppConfig.String("OSSLogBucket"); strings.TrimSpace(bucket) != "" {
			provider = "oss"
		} else {
			provider = "local"
		}
	}

	switch provider {
	case "local":
		dir, _ := web.AppConfig.String("LocalLogDir")
		if strings.TrimSpace(dir) == "" {
			dir = "/var/log/openvpn-ui/archives"
		}
		return newLocal(dir), nil
	case "oss":
		bucket, _ := web.AppConfig.String("OSSLogBucket")
		endpoint, _ := web.AppConfig.String("OSSEndpoint")
		if strings.TrimSpace(bucket) == "" {
			return nil, fmt.Errorf("StorageProvider=oss but OSSLogBucket is empty")
		}
		return newOSS(bucket, endpoint), nil
	case "s3":
		bucket, _ := web.AppConfig.String("S3LogBucket")
		region, _ := web.AppConfig.String("S3Region")
		if strings.TrimSpace(bucket) == "" {
			return nil, fmt.Errorf("StorageProvider=s3 but S3LogBucket is empty")
		}
		if strings.TrimSpace(region) == "" {
			return nil, fmt.Errorf("StorageProvider=s3 but S3Region is empty")
		}
		return newS3(bucket, region), nil
	case "gcs":
		bucket, _ := web.AppConfig.String("GCSLogBucket")
		keyFile, _ := web.AppConfig.String("GCSServiceAccountKeyFile")
		if strings.TrimSpace(bucket) == "" {
			return nil, fmt.Errorf("StorageProvider=gcs but GCSLogBucket is empty")
		}
		return newGCS(bucket, strings.TrimSpace(keyFile)), nil
	default:
		return nil, fmt.Errorf("unknown StorageProvider %q (supported: local, oss, s3, gcs)", provider)
	}
}

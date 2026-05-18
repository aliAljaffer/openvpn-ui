package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"sort"
	"strings"

	"cloud.google.com/go/storage"
	"google.golang.org/api/iterator"
	"google.golang.org/api/option"
)

type gcsBackend struct {
	bucket  string
	keyFile string
}

func newGCS(bucket, keyFile string) *gcsBackend {
	return &gcsBackend{bucket: bucket, keyFile: keyFile}
}

func (g *gcsBackend) client(ctx context.Context) (*storage.Client, error) {
	if g.keyFile != "" {
		return storage.NewClient(ctx, option.WithCredentialsFile(g.keyFile))
	}
	return storage.NewClient(ctx)
}

func (g *gcsBackend) List(ctx context.Context, prefix string) ([]string, error) {
	c, err := g.client(ctx)
	if err != nil {
		return nil, fmt.Errorf("gcs client: %w", err)
	}
	defer c.Close()

	var files []string
	it := c.Bucket(g.bucket).Objects(ctx, &storage.Query{Prefix: prefix})
	for {
		attrs, err := it.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("gcs list: %w", err)
		}
		name := path.Base(attrs.Name)
		if strings.HasSuffix(name, ".log.gz") {
			files = append(files, name)
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(files)))
	return files, nil
}

func (g *gcsBackend) Download(ctx context.Context, key, localDir string) (string, func(), error) {
	c, err := g.client(ctx)
	if err != nil {
		return "", func() {}, fmt.Errorf("gcs client: %w", err)
	}
	defer c.Close()

	r, err := c.Bucket(g.bucket).Object(key).NewReader(ctx)
	if err != nil {
		return "", func() {}, fmt.Errorf("gcs download %s: %w", key, err)
	}
	defer r.Close()

	dest := localDir + "/" + key
	f, err := os.Create(dest)
	if err != nil {
		return "", func() {}, fmt.Errorf("create %s: %w", dest, err)
	}
	if _, err := io.Copy(f, r); err != nil {
		_ = f.Close()
		_ = os.Remove(dest)
		return "", func() {}, fmt.Errorf("write %s: %w", dest, err)
	}
	_ = f.Close()
	cleanup := func() { _ = os.Remove(dest) }
	return dest, cleanup, nil
}

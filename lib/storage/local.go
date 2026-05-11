package storage

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strings"
)

type localBackend struct {
	dir string
}

func newLocal(dir string) *localBackend {
	return &localBackend{dir: dir}
}

func (l *localBackend) List(_ context.Context, prefix string) ([]string, error) {
	entries, err := os.ReadDir(l.dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read %s: %w", l.dir, err)
	}
	var files []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, prefix) || !strings.HasSuffix(name, ".log.gz") {
			continue
		}
		files = append(files, name)
	}
	sort.Sort(sort.Reverse(sort.StringSlice(files)))
	return files, nil
}

// Download for the local backend returns the original archive path; nothing
// is copied and cleanup is a no-op. The returned path lives inside the
// configured LocalLogDir, so callers MUST treat it as read-only.
func (l *localBackend) Download(_ context.Context, key, _ string) (string, func(), error) {
	path := l.dir + "/" + key
	if _, err := os.Stat(path); err != nil {
		return "", func() {}, fmt.Errorf("stat %s: %w", path, err)
	}
	return path, func() {}, nil
}

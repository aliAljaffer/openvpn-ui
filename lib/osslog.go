package lib

import (
	"fmt"
	"os/exec"
	"path"
	"sort"
	"strings"
)

// ListOSSArchives returns filenames (e.g. "openvpn-logs-2024-04-14-235959.log.gz")
// of log archives stored in the OSS bucket, sorted newest-first.
// ossutil reads credentials from ~/.ossutilconfig (mounted into the container).
func ListOSSArchives(bucket, endpoint string) ([]string, error) {
	out, err := exec.Command("ossutil", "ls",
		"oss://"+bucket+"/",
		"--endpoint", endpoint).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("ossutil ls: %s: %w", strings.TrimSpace(string(out)), err)
	}
	var files []string
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasSuffix(line, ".log.gz") {
			parts := strings.Fields(line)
			if len(parts) > 0 {
				// Last field is the full OSS path, e.g. oss://bucket/file.log.gz
				files = append(files, path.Base(parts[len(parts)-1]))
			}
		}
	}
	// Filenames encode the rotation timestamp so lexicographic reverse == newest-first.
	sort.Sort(sort.Reverse(sort.StringSlice(files)))
	return files, nil
}

// DownloadOSSArchive fetches a named archive from OSS into localDir
// and returns the full local path.
func DownloadOSSArchive(bucket, endpoint, filename, localDir string) (string, error) {
	dest := localDir + "/" + filename
	src := "oss://" + bucket + "/" + filename
	out, err := exec.Command("ossutil", "cp", src, dest,
		"--endpoint", endpoint, "-f").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("ossutil cp: %s: %w", strings.TrimSpace(string(out)), err)
	}
	return dest, nil
}

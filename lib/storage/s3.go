package storage

import (
	"context"
	"fmt"
	"io"
	"os"
	"path"
	"sort"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

type s3Backend struct {
	bucket string
	region string
}

func newS3(bucket, region string) *s3Backend {
	return &s3Backend{bucket: bucket, region: region}
}

func (b *s3Backend) client(ctx context.Context) (*s3.Client, error) {
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(b.region))
	if err != nil {
		return nil, fmt.Errorf("aws config: %w", err)
	}
	return s3.NewFromConfig(cfg), nil
}

func (b *s3Backend) List(ctx context.Context, prefix string) ([]string, error) {
	c, err := b.client(ctx)
	if err != nil {
		return nil, err
	}
	var files []string
	var token *string
	for {
		out, err := c.ListObjectsV2(ctx, &s3.ListObjectsV2Input{
			Bucket:            aws.String(b.bucket),
			Prefix:            aws.String(prefix),
			ContinuationToken: token,
		})
		if err != nil {
			return nil, fmt.Errorf("s3 list: %w", err)
		}
		for _, obj := range out.Contents {
			if obj.Key == nil {
				continue
			}
			name := path.Base(*obj.Key)
			if strings.HasSuffix(name, ".log.gz") {
				files = append(files, name)
			}
		}
		if out.IsTruncated == nil || !*out.IsTruncated {
			break
		}
		token = out.NextContinuationToken
	}
	sort.Sort(sort.Reverse(sort.StringSlice(files)))
	return files, nil
}

func (b *s3Backend) Download(ctx context.Context, key, localDir string) (string, func(), error) {
	c, err := b.client(ctx)
	if err != nil {
		return "", func() {}, err
	}
	out, err := c.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(b.bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return "", func() {}, fmt.Errorf("s3 download %s: %w", key, err)
	}
	defer out.Body.Close()

	dest := localDir + "/" + key
	f, err := os.Create(dest)
	if err != nil {
		return "", func() {}, fmt.Errorf("create %s: %w", dest, err)
	}
	if _, err := io.Copy(f, out.Body); err != nil {
		_ = f.Close()
		_ = os.Remove(dest)
		return "", func() {}, fmt.Errorf("write %s: %w", dest, err)
	}
	_ = f.Close()
	cleanup := func() { _ = os.Remove(dest) }
	return dest, cleanup, nil
}

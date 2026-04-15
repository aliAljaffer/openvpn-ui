package lib

import (
	"bufio"
	"compress/gzip"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"
)

// AuditEvent represents a single client connect/disconnect session parsed from
// journald short-iso log lines written by ovpn-log-collect.sh.
type AuditEvent struct {
	CN             string
	SourceIP       string
	ConnectTime    time.Time
	DisconnectTime time.Time // zero if still connected in this archive
	Duration       string    // human-readable; empty if still connected
}

// journald short-iso line format:
//
//	2025-04-14T16:23:01+0000 hostname openvpn[pid]: CN/IP:PORT MESSAGE
var (
	connectRE = regexp.MustCompile(
		`^(\S+)\s+\S+\s+openvpn\[\d+\]:\s+(\S+)/(\d+\.\d+\.\d+\.\d+):\d+\s+MULTI:\s+Learn`)
	disconnectRE = regexp.MustCompile(
		`^(\S+)\s+\S+\s+openvpn\[\d+\]:\s+(\S+)/(\d+\.\d+\.\d+\.\d+):\d+\s+(Connection reset|client-instance exiting)`)
)

const tsLayout = "2006-01-02T15:04:05-0700"

// ParseLogFile reads a plain or gzip-compressed journald short-iso log file and
// returns audit events. Connect lines (MULTI: Learn) are correlated with disconnect
// lines (Connection reset / client-instance exiting) keyed by CN+sourceIP.
// Sessions with no matching disconnect are returned with a zero DisconnectTime.
func ParseLogFile(filePath string) ([]AuditEvent, error) {
	f, err := os.Open(filePath)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", filePath, err)
	}
	defer f.Close()

	var scanner *bufio.Scanner
	if strings.HasSuffix(filePath, ".gz") {
		gr, err := gzip.NewReader(f)
		if err != nil {
			return nil, fmt.Errorf("gzip reader: %w", err)
		}
		defer gr.Close()
		scanner = bufio.NewScanner(gr)
	} else {
		scanner = bufio.NewScanner(f)
	}

	// open sessions: key = "CN/sourceIP"
	open := map[string]*AuditEvent{}
	var events []AuditEvent

	for scanner.Scan() {
		line := scanner.Text()

		if m := connectRE.FindStringSubmatch(line); m != nil {
			ts, _ := time.Parse(tsLayout, m[1])
			key := m[2] + "/" + m[3]
			open[key] = &AuditEvent{
				CN:          m[2],
				SourceIP:    m[3],
				ConnectTime: ts,
			}
		} else if m := disconnectRE.FindStringSubmatch(line); m != nil {
			ts, _ := time.Parse(tsLayout, m[1])
			key := m[2] + "/" + m[3]
			if ev, ok := open[key]; ok {
				ev.DisconnectTime = ts
				if !ev.ConnectTime.IsZero() {
					ev.Duration = ts.Sub(ev.ConnectTime).Round(time.Second).String()
				}
				events = append(events, *ev)
				delete(open, key)
			}
		}
	}

	// Sessions with no disconnect line in this archive (still connected or
	// disconnect event was in a later archive).
	for _, ev := range open {
		events = append(events, *ev)
	}

	return events, scanner.Err()
}

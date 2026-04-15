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
//	2026-04-15T14:49:28+0800 openvpn openvpn[858]: tcp4-server:IP:PORT [CN] Peer Connection Initiated with [AF_INET]IP:PORT
//	2026-04-15T15:15:14+0800 openvpn openvpn[858]: CN/tcp4-server:IP:PORT Connection reset, restarting [-1]
var (
	// connectRE matches the "Peer Connection Initiated" line where the CN appears in [brackets].
	// Groups: (1) timestamp  (2) source IP  (3) CN
	connectRE = regexp.MustCompile(
		`^(\S+)\s+\S+\s+openvpn\[\d+\]:\s+\S+:(\d+\.\d+\.\d+\.\d+):\d+\s+\[([^\]]+)\]\s+Peer Connection Initiated`)

	// disconnectRE matches lines whose context prefix is CN/tcp4-server:IP:PORT and that
	// signal the end of the session ("Connection reset", SIGUSR1/SIGTERM client-instance lines).
	// Groups: (1) timestamp  (2) CN  (3) source IP
	disconnectRE = regexp.MustCompile(
		`^(\S+)\s+\S+\s+openvpn\[\d+\]:\s+([^/\s]+)/\S+:(\d+\.\d+\.\d+\.\d+):\d+\s+(?:Connection reset|client-instance (?:restarting|exiting))`)
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
			// m[2]=sourceIP, m[3]=CN
			key := m[3] + "/" + m[2]
			open[key] = &AuditEvent{
				CN:          m[3],
				SourceIP:    m[2],
				ConnectTime: ts,
			}
		} else if m := disconnectRE.FindStringSubmatch(line); m != nil {
			ts, _ := time.Parse(tsLayout, m[1])
			// m[2]=CN, m[3]=sourceIP
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

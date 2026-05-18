package controllers

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/beego/beego/v2/core/logs"
	"github.com/beego/beego/v2/server/web"
	mi "github.com/d3vilh/openvpn-server-config/server/mi"
	"github.com/d3vilh/openvpn-ui/lib"
	"github.com/d3vilh/openvpn-ui/state"
)

// APIMetricsController exposes read-only VPN telemetry for centralized monitoring.
// Default-deny: when MetricsAuthToken is empty in app.conf, every endpoint returns 404.
// When configured, the token must be presented as `Authorization: Bearer <token>`.
// Session-cookie auth used by the rest of the UI does NOT grant access here.
type APIMetricsController struct {
	web.Controller
}

type metricsResponse struct {
	GeneratedAt string      `json:"generated_at"`
	Data        interface{} `json:"data"`
}

type metricsSummary struct {
	NConnected         int `json:"n_connected"`
	NRecentDisconnects int `json:"n_recent_disconnects"`
	NPortForwards      int `json:"n_port_forwards"`
	NCertsActive       int `json:"n_certs_active"`
	NCertsRevoked      int `json:"n_certs_revoked"`
	NCertsExpiring     int `json:"n_certs_expiring"`
	NCertsExpired      int `json:"n_certs_expired"`
}

type metricsClient struct {
	CN             string  `json:"cn"`
	RealIP         string  `json:"real_ip"`
	VirtualIP      string  `json:"virtual_ip"`
	BytesReceived  uint64  `json:"bytes_received"`
	BytesSent      uint64  `json:"bytes_sent"`
	ConnectedSince string  `json:"connected_since"`
	Country        string  `json:"country,omitempty"`
	City           string  `json:"city,omitempty"`
	Latitude       float64 `json:"latitude,omitempty"`
	Longitude      float64 `json:"longitude,omitempty"`
}

type metricsDisconnect struct {
	CN             string `json:"cn"`
	SourceIP       string `json:"source_ip"`
	ConnectTime    string `json:"connect_time,omitempty"`
	DisconnectTime string `json:"disconnect_time"`
	Duration       string `json:"duration,omitempty"`
}

type metricsCerts struct {
	Active      int                 `json:"active"`
	Revoked     int                 `json:"revoked"`
	Expiring30d int                 `json:"expiring_30d"`
	Expired     int                 `json:"expired"`
	ByCN        []metricsCertEntry  `json:"by_cn"`
}

type metricsCertEntry struct {
	cn         string
	CN         string `json:"cn"`
	EntryType  string `json:"entry_type"`
	Expiration string `json:"expiration"`
	Expired    bool   `json:"expired"`
	IsExpiring bool   `json:"is_expiring"`
}

var (
	metricsCacheMu      sync.Mutex
	cachedSummary       *metricsSummary
	cachedSummaryAt     time.Time
	cachedClients       []metricsClient
	cachedClientsAt     time.Time
)

const metricsMasterLogPath = "/opt/scripts/ovpn-master.log"

// Prepare gates the entire namespace on a bearer token.
// Empty token => 404 (do not advertise existence).
// Wrong token => 401.
func (c *APIMetricsController) Prepare() {
	c.EnableXSRF = false

	token, _ := web.AppConfig.String("MetricsAuthToken")
	token = strings.TrimSpace(token)
	if token == "" {
		c.Ctx.Output.SetStatus(404)
		c.Ctx.Output.Body([]byte(""))
		c.StopRun()
		return
	}

	auth := c.Ctx.Input.Header("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") {
		c.unauth()
		return
	}
	supplied := strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
	if subtle.ConstantTimeCompare([]byte(supplied), []byte(token)) != 1 {
		c.unauth()
		return
	}
}

func (c *APIMetricsController) unauth() {
	c.Ctx.Output.SetStatus(401)
	c.Ctx.Output.Header("WWW-Authenticate", "Bearer")
	c.Ctx.Output.JSON(map[string]string{"status": "error", "message": "unauthorized"}, false, false)
	c.StopRun()
}

func (c *APIMetricsController) reply(data interface{}) {
	c.Data["json"] = metricsResponse{
		GeneratedAt: time.Now().UTC().Format(time.RFC3339),
		Data:        data,
	}
	c.ServeJSON()
}

// Summary returns scalar counts only. Cached per MetricsCacheSeconds.
// @router /summary [get]
func (c *APIMetricsController) Summary() {
	cacheSec := metricsCacheSeconds()
	metricsCacheMu.Lock()
	if cachedSummary != nil && time.Since(cachedSummaryAt) < time.Duration(cacheSec)*time.Second {
		s := *cachedSummary
		metricsCacheMu.Unlock()
		c.reply(s)
		return
	}
	metricsCacheMu.Unlock()

	s := metricsSummary{}

	if clients, err := getMIClients(); err == nil {
		s.NConnected = len(clients)
	}

	disc := loadDisconnects(time.Duration(disconnectsWindowHours())*time.Hour, nil)
	s.NRecentDisconnects = len(disc)

	if rules, _, err := listRules(); err == nil {
		s.NPortForwards = len(rules)
	}

	certs := loadCerts()
	s.NCertsActive = certs.Active
	s.NCertsRevoked = certs.Revoked
	s.NCertsExpiring = certs.Expiring30d
	s.NCertsExpired = certs.Expired

	metricsCacheMu.Lock()
	cachedSummary = &s
	cachedSummaryAt = time.Now()
	metricsCacheMu.Unlock()

	c.reply(s)
}

// Clients returns the list of currently connected clients, geo-enriched if a
// MaxMind DB is configured. Cached per MetricsCacheSeconds.
// @router /clients [get]
func (c *APIMetricsController) Clients() {
	cacheSec := metricsCacheSeconds()
	metricsCacheMu.Lock()
	if cachedClients != nil && time.Since(cachedClientsAt) < time.Duration(cacheSec)*time.Second {
		out := make([]metricsClient, len(cachedClients))
		copy(out, cachedClients)
		metricsCacheMu.Unlock()
		c.reply(out)
		return
	}
	metricsCacheMu.Unlock()

	clients, err := getMIClients()
	if err != nil {
		logs.Warn("api-metrics: MI error:", err)
		c.reply([]metricsClient{})
		return
	}

	dbPath, _ := web.AppConfig.String("GeoipDbPath")
	hash := hashClientNames()

	out := make([]metricsClient, 0, len(clients))
	if dbPath != "" {
		if geo, err := lib.EnrichWithGeo(clients, dbPath); err == nil {
			for _, g := range geo {
				out = append(out, metricsClientFromGeo(g, hash))
			}
		} else {
			for _, cl := range clients {
				out = append(out, metricsClientFromMI(cl, hash))
			}
		}
	} else {
		for _, cl := range clients {
			out = append(out, metricsClientFromMI(cl, hash))
		}
	}

	metricsCacheMu.Lock()
	cachedClients = out
	cachedClientsAt = time.Now()
	metricsCacheMu.Unlock()

	c.reply(out)
}

// Disconnects returns sessions whose disconnect time falls within the window.
// Query param: ?window=Nh (default DisconnectsWindowH from app.conf).
// @router /disconnects [get]
func (c *APIMetricsController) Disconnects() {
	winH := disconnectsWindowHours()
	if q := strings.TrimSpace(c.GetString("window")); q != "" {
		if v, err := parseWindow(q); err == nil {
			winH = v
		}
	}

	activeCNs := map[string]bool{}
	if clients, err := getMIClients(); err == nil {
		for _, cl := range clients {
			activeCNs[cl.CommonName] = true
		}
	}

	events := loadDisconnects(time.Duration(winH)*time.Hour, activeCNs)
	hash := hashClientNames()

	out := make([]metricsDisconnect, 0, len(events))
	for _, ev := range events {
		out = append(out, metricsDisconnect{
			CN:             maybeHash(ev.CN, hash),
			SourceIP:       ev.SourceIP,
			ConnectTime:    formatTime(ev.ConnectTime),
			DisconnectTime: formatTime(ev.DisconnectTime),
			Duration:       ev.Duration,
		})
	}

	c.reply(out)
}

// PortForwards proxies `port-forward.sh list --format json`.
// @router /portforwards [get]
func (c *APIMetricsController) PortForwards() {
	rules, ipForward, err := listRules()
	if err != nil {
		logs.Warn("api-metrics: port-forward list failed:", err)
		c.reply(map[string]interface{}{"ip_forward": 0, "rules": []PortForwardRule{}})
		return
	}
	c.reply(map[string]interface{}{"ip_forward": ipForward, "rules": rules})
}

// Certificates returns counts plus a per-CN inventory.
// @router /certificates [get]
func (c *APIMetricsController) Certificates() {
	c.reply(loadCerts())
}

// Prometheus renders the same data in the Prometheus text exposition format.
// Same token-gated namespace; content-type is text/plain; version=0.0.4.
// @router /prometheus [get]
func (c *APIMetricsController) Prometheus() {
	var b strings.Builder

	clients, _ := getMIClients()
	disc := loadDisconnects(time.Duration(disconnectsWindowHours())*time.Hour, nil)
	rules, ipForward, _ := listRules()
	certs := loadCerts()
	now := time.Now().Unix()
	hash := hashClientNames()

	writeHelp := func(name, help, kind string) {
		fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s %s\n", name, help, name, kind)
	}

	writeHelp("openvpn_connected_clients", "Number of currently connected VPN clients.", "gauge")
	fmt.Fprintf(&b, "openvpn_connected_clients %d\n", len(clients))

	writeHelp("openvpn_recent_disconnects", "Disconnects within the configured window.", "gauge")
	fmt.Fprintf(&b, "openvpn_recent_disconnects %d\n", len(disc))

	writeHelp("openvpn_port_forwards", "Active NAT port-forward rules.", "gauge")
	fmt.Fprintf(&b, "openvpn_port_forwards %d\n", len(rules))

	writeHelp("openvpn_ip_forward_enabled", "1 if net.ipv4.ip_forward=1.", "gauge")
	fmt.Fprintf(&b, "openvpn_ip_forward_enabled %d\n", ipForward)

	writeHelp("openvpn_certs", "Certificate inventory by state.", "gauge")
	fmt.Fprintf(&b, "openvpn_certs{state=\"active\"} %d\n", certs.Active)
	fmt.Fprintf(&b, "openvpn_certs{state=\"revoked\"} %d\n", certs.Revoked)
	fmt.Fprintf(&b, "openvpn_certs{state=\"expiring_30d\"} %d\n", certs.Expiring30d)
	fmt.Fprintf(&b, "openvpn_certs{state=\"expired\"} %d\n", certs.Expired)

	writeHelp("openvpn_client_bytes_received", "Bytes received from a connected client (cumulative for the session).", "counter")
	writeHelp("openvpn_client_bytes_sent", "Bytes sent to a connected client (cumulative for the session).", "counter")
	writeHelp("openvpn_client_connected_since_seconds", "Unix timestamp (seconds) when the client connected.", "gauge")

	dbPath, _ := web.AppConfig.String("GeoipDbPath")
	type clientMetric struct {
		cn, realIP, virtualIP, country, city string
		bytesIn, bytesOut                    uint64
		since                                int64
	}
	var cms []clientMetric
	if dbPath != "" {
		if geo, err := lib.EnrichWithGeo(clients, dbPath); err == nil {
			for _, g := range geo {
				cms = append(cms, clientMetric{
					cn: maybeHash(g.CommonName, hash), realIP: g.RealAddress, virtualIP: g.VirtualAddress,
					country: g.Country, city: g.City,
					bytesIn: g.BytesReceived, bytesOut: g.BytesSent,
					since: parseConnectedSince(g.ConnectedSince),
				})
			}
		}
	}
	if len(cms) == 0 {
		for _, cl := range clients {
			cms = append(cms, clientMetric{
				cn: maybeHash(cl.CommonName, hash), realIP: cl.RealAddress, virtualIP: cl.VirtualAddress,
				bytesIn: cl.BytesReceived, bytesOut: cl.BytesSent,
				since: parseConnectedSince(cl.ConnectedSince),
			})
		}
	}
	sort.Slice(cms, func(i, j int) bool { return cms[i].cn < cms[j].cn })
	for _, m := range cms {
		labels := promLabels("cn", m.cn, "real_ip", m.realIP, "virtual_ip", m.virtualIP, "country", m.country, "city", m.city)
		fmt.Fprintf(&b, "openvpn_client_bytes_received{%s} %d\n", labels, m.bytesIn)
		fmt.Fprintf(&b, "openvpn_client_bytes_sent{%s} %d\n", labels, m.bytesOut)
		if m.since > 0 {
			fmt.Fprintf(&b, "openvpn_client_connected_since_seconds{%s} %d\n", labels, m.since)
		}
	}

	writeHelp("openvpn_cert_info", "Per-CN certificate state. value=1.", "gauge")
	for _, e := range certs.ByCN {
		labels := promLabels("cn", e.cn, "entry_type", e.EntryType, "expired", boolStr(e.Expired), "expiring_30d", boolStr(e.IsExpiring))
		fmt.Fprintf(&b, "openvpn_cert_info{%s} 1\n", labels)
	}

	writeHelp("openvpn_port_forward_info", "Per-rule NAT port forward. value=1.", "gauge")
	for _, r := range rules {
		labels := promLabels("listen_port", strconv.Itoa(r.ListenPort), "dest_ip", r.DestIP, "dest_port", strconv.Itoa(r.DestPort))
		fmt.Fprintf(&b, "openvpn_port_forward_info{%s} 1\n", labels)
	}

	writeHelp("openvpn_metrics_generated_at", "Unix timestamp of this scrape.", "gauge")
	fmt.Fprintf(&b, "openvpn_metrics_generated_at %d\n", now)

	c.Ctx.Output.Header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	c.Ctx.Output.Body([]byte(b.String()))
}

func promLabels(kv ...string) string {
	var parts []string
	for i := 0; i+1 < len(kv); i += 2 {
		k := kv[i]
		v := kv[i+1]
		if v == "" {
			continue
		}
		parts = append(parts, fmt.Sprintf("%s=%q", k, escapePromLabel(v)))
	}
	return strings.Join(parts, ",")
}

func escapePromLabel(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	s = strings.ReplaceAll(s, "\n", `\n`)
	return s
}

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

// parseConnectedSince accepts OpenVPN's status-format timestamp
// (e.g. "Wed May  7 12:34:56 2026") and returns a Unix epoch.
// Returns 0 if the input is empty or unparseable.
func parseConnectedSince(s string) int64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	for _, layout := range []string{
		"Mon Jan _2 15:04:05 2006",
		"2006-01-02 15:04:05",
		time.RFC3339,
	} {
		if t, err := time.Parse(layout, s); err == nil {
			return t.Unix()
		}
	}
	return 0
}

// --- helpers --------------------------------------------------------------

func metricsCacheSeconds() int {
	v, err := web.AppConfig.Int("MetricsCacheSeconds")
	if err != nil || v < 0 {
		return 5
	}
	return v
}

func disconnectsWindowHours() int {
	v, err := web.AppConfig.Int("DisconnectsWindowH")
	if err != nil || v <= 0 {
		return 24
	}
	return v
}

func hashClientNames() bool {
	v, err := web.AppConfig.Bool("MetricsHashClientNames")
	if err != nil {
		return false
	}
	return v
}

func parseWindow(s string) (int, error) {
	s = strings.TrimSpace(strings.TrimSuffix(s, "h"))
	return strconv.Atoi(s)
}

func maybeHash(cn string, hash bool) string {
	if !hash || cn == "" {
		return cn
	}
	sum := sha256.Sum256([]byte(cn))
	return hex.EncodeToString(sum[:8])
}

func formatTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

func getMIClients() ([]*mi.OVClient, error) {
	client := mi.NewClient(state.GlobalCfg.MINetwork, state.GlobalCfg.MIAddress)
	status, err := client.GetStatus()
	if err != nil {
		return nil, err
	}
	return status.ClientList, nil
}

func metricsClientFromMI(cl *mi.OVClient, hash bool) metricsClient {
	return metricsClient{
		CN:             maybeHash(cl.CommonName, hash),
		RealIP:         cl.RealAddress,
		VirtualIP:      cl.VirtualAddress,
		BytesReceived:  cl.BytesReceived,
		BytesSent:      cl.BytesSent,
		ConnectedSince: cl.ConnectedSince,
	}
}

func metricsClientFromGeo(g lib.GeoClient, hash bool) metricsClient {
	m := metricsClientFromMI(&g.OVClient, hash)
	m.Country = g.Country
	m.City = g.City
	m.Latitude = g.Latitude
	m.Longitude = g.Longitude
	return m
}

func loadDisconnects(window time.Duration, excludeActive map[string]bool) []lib.AuditEvent {
	sessions, err := lib.ParseLogFile(metricsMasterLogPath)
	if err != nil {
		return nil
	}
	cutoff := time.Now().Add(-window)
	out := make([]lib.AuditEvent, 0, len(sessions))
	for _, ev := range sessions {
		if ev.DisconnectTime.IsZero() {
			continue
		}
		if ev.DisconnectTime.Before(cutoff) {
			continue
		}
		if excludeActive != nil && excludeActive[ev.CN] {
			continue
		}
		out = append(out, ev)
	}
	return out
}

func loadCerts() metricsCerts {
	out := metricsCerts{ByCN: []metricsCertEntry{}}
	indexPath := filepath.Join(state.GlobalCfg.OVConfigPath, "pki", "index.txt")
	if _, err := os.Stat(indexPath); err != nil {
		return out
	}
	certs, err := lib.ReadCerts(indexPath)
	if err != nil {
		logs.Warn("api-metrics: ReadCerts:", err)
		return out
	}
	now := time.Now()
	hash := hashClientNames()
	for _, ct := range certs {
		entryType := strings.ToUpper(strings.TrimSpace(ct.EntryType))
		cn := ""
		if ct.Details != nil {
			cn = ct.Details.CN
		}
		expired := !ct.ExpirationT.IsZero() && ct.ExpirationT.Before(now)
		switch entryType {
		case "R":
			out.Revoked++
		case "V":
			out.Active++
			if expired {
				out.Expired++
			} else if ct.IsExpiring {
				out.Expiring30d++
			}
		case "E":
			out.Expired++
		}
		hashedCN := maybeHash(cn, hash)
		out.ByCN = append(out.ByCN, metricsCertEntry{
			cn:         hashedCN,
			CN:         hashedCN,
			EntryType:  entryType,
			Expiration: formatTime(ct.ExpirationT),
			Expired:    expired,
			IsExpiring: ct.IsExpiring,
		})
	}
	return out
}

package controllers

import (
	"encoding/json"
	"html/template"
	"time"

	"github.com/beego/beego/v2/core/logs"
	beegoWeb "github.com/beego/beego/v2/server/web"
	mi "github.com/d3vilh/openvpn-server-config/server/mi"
	"github.com/d3vilh/openvpn-ui/lib"
	"github.com/d3vilh/openvpn-ui/state"
)

// MapViewController renders the /map page showing connected VPN clients
// plotted on a world map using MaxMind GeoLite2-City data.
type MapViewController struct {
	BaseController
}

func (c *MapViewController) NestPrepare() {
	if !c.IsLogin {
		c.Ctx.Redirect(302, c.LoginPath())
		return
	}
}

func (c *MapViewController) Get() {
	c.Data["breadcrumbs"] = &BreadCrumbs{
		Title: "Map View",
	}

	dbPath, _ := beegoWeb.AppConfig.String("GeoipDbPath")

	// Fetch connected clients from the management interface.
	client := mi.NewClient(state.GlobalCfg.MINetwork, state.GlobalCfg.MIAddress)
	status, err := client.GetStatus()
	if err != nil {
		logs.Error("MapView: MI error:", err)
		c.Data["GeoIPError"] = "Could not connect to OpenVPN management interface: " + err.Error()
		c.Data["MapClientsJSON"] = template.JS("[]")
		c.TplName = "mapview.html"
		return
	}

	if dbPath == "" {
		c.Data["GeoIPError"] = "GeoipDbPath is not configured. Set it in conf/app.conf to enable map markers."
		raw, _ := json.Marshal([]struct{}{})
		c.Data["MapClientsJSON"] = template.JS(raw)
		c.TplName = "mapview.html"
		return
	}

	geoClients, err := lib.EnrichWithGeo(status.ClientList, dbPath)
	if err != nil {
		logs.Warn("MapView: GeoIP DB unavailable:", err)
		c.Data["GeoIPError"] = "GeoIP database could not be opened: " + err.Error()
		// Still show clients (unlocated) so the page isn't blank.
		geoClients = make([]lib.GeoClient, 0, len(status.ClientList))
		for _, cl := range status.ClientList {
			geoClients = append(geoClients, lib.GeoClient{OVClient: *cl})
		}
	}

	// Append recently-disconnected clients as faded markers.
	geoClients = appendRecentDisconnects(geoClients, status.ClientList, dbPath)

	clientsJSON, _ := json.Marshal(geoClients)
	c.Data["MapClientsJSON"] = template.JS(clientsJSON)
	c.Data["GeoIPError"] = ""
	c.TplName = "mapview.html"
}

const (
	masterLogPath   = "/opt/scripts/ovpn-master.log"
	recentWindow    = 4 * time.Hour
)

// appendRecentDisconnects parses the current master log, finds sessions that
// ended within the last recentWindow and are not currently in the MI client list,
// geo-enriches them, and appends them to geoClients as IsDisconnected entries.
func appendRecentDisconnects(geoClients []lib.GeoClient, active []*mi.OVClient, dbPath string) []lib.GeoClient {
	sessions, err := lib.ParseLogFile(masterLogPath)
	if err != nil || len(sessions) == 0 {
		return geoClients
	}

	activeCNs := map[string]bool{}
	for _, c := range active {
		activeCNs[c.CommonName] = true
	}

	cutoff := time.Now().Add(-recentWindow)
	var recentIPs []string
	var recentSessions []lib.AuditEvent
	// Deduplicate: keep only the most recent disconnect per CN.
	latest := map[string]lib.AuditEvent{}
	for _, ev := range sessions {
		if ev.DisconnectTime.IsZero() || ev.DisconnectTime.Before(cutoff) {
			continue
		}
		if activeCNs[ev.CN] {
			continue
		}
		if prev, ok := latest[ev.CN]; !ok || ev.DisconnectTime.After(prev.DisconnectTime) {
			latest[ev.CN] = ev
		}
	}
	for _, ev := range latest {
		recentIPs = append(recentIPs, ev.SourceIP)
		recentSessions = append(recentSessions, ev)
	}

	if len(recentSessions) == 0 {
		return geoClients
	}

	geoMap := lib.GeoLookupBatch(dbPath, recentIPs)
	for _, ev := range recentSessions {
		gc := lib.GeoClient{
			IsDisconnected: true,
			DisconnectedAt: ev.DisconnectTime.Format("15:04:05"),
			Duration:       ev.Duration,
		}
		gc.CommonName = ev.CN
		gc.RealAddress = ev.SourceIP
		if loc, ok := geoMap[ev.SourceIP]; ok {
			gc.Country = loc.Country
			gc.City = loc.City
			gc.Latitude = loc.Latitude
			gc.Longitude = loc.Longitude
			gc.Located = loc.Latitude != 0 || loc.Longitude != 0
		}
		geoClients = append(geoClients, gc)
	}
	return geoClients
}

package controllers

import (
	"encoding/json"
	"html/template"
	"os"
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
	recentDisconnectsDefaultPath = "/opt/scripts/recent-disconnects.json"
	recentWindow                 = time.Hour
)

// recentDisconnect is one entry in the JSON store written by
// host/scripts/client-disconnect.sh (and seed-recent-disconnects.sh).
//
// The live hook writes only cn/ip/epoch/duration and lets the controller
// geo-enrich by IP (mirroring the active-client path). Country/City/Lat/Lng are
// optional: when present (e.g. from the seed) they're used as-is, so a marker
// shows even if the GeoIP DB can't resolve that IP.
type recentDisconnect struct {
	CN       string  `json:"cn"`
	IP       string  `json:"ip"`
	Epoch    int64   `json:"disconnect_epoch"`
	Duration string  `json:"duration"`
	Country  string  `json:"country,omitempty"`
	City     string  `json:"city,omitempty"`
	Lat      float64 `json:"lat,omitempty"`
	Lng      float64 `json:"lng,omitempty"`
}

// appendRecentDisconnects reads the recent-disconnects JSON store, keeps sessions
// that ended within the last recentWindow and are not currently connected,
// geo-enriches them, and appends them to geoClients as IsDisconnected entries.
//
// The store is populated by the OpenVPN client-disconnect hook rather than parsed
// from the rolling master log, so disconnect events survive log rotation.
func appendRecentDisconnects(geoClients []lib.GeoClient, active []*mi.OVClient, dbPath string) []lib.GeoClient {
	path, _ := beegoWeb.AppConfig.String("RecentDisconnectsPath")
	if path == "" {
		path = recentDisconnectsDefaultPath
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		// Missing store just means no disconnects have been recorded yet.
		return geoClients
	}

	var records []recentDisconnect
	if err := json.Unmarshal(raw, &records); err != nil {
		logs.Warn("MapView: could not parse recent-disconnects store:", err)
		return geoClients
	}

	activeCNs := map[string]bool{}
	for _, c := range active {
		activeCNs[c.CommonName] = true
	}

	cutoff := time.Now().Add(-recentWindow).Unix()
	// Deduplicate by CN+IP, keeping the most recent disconnect per location.
	latest := map[string]recentDisconnect{}
	for _, r := range records {
		if r.Epoch < cutoff {
			continue
		}
		if activeCNs[r.CN] {
			continue
		}
		key := r.CN + "|" + r.IP
		if prev, ok := latest[key]; !ok || r.Epoch > prev.Epoch {
			latest[key] = r
		}
	}

	if len(latest) == 0 {
		return geoClients
	}

	// Only resolve IPs that don't already carry coordinates.
	var ips []string
	for _, r := range latest {
		if r.Lat == 0 && r.Lng == 0 {
			ips = append(ips, r.IP)
		}
	}
	geoMap := lib.GeoLookupBatch(dbPath, ips)

	for _, r := range latest {
		gc := lib.GeoClient{
			IsDisconnected: true,
			DisconnectedAt: time.Unix(r.Epoch, 0).Format("2006-01-02 15:04:05"),
			Duration:       r.Duration,
		}
		gc.CommonName = r.CN
		gc.RealAddress = r.IP
		if r.Lat != 0 || r.Lng != 0 {
			// Coordinates supplied directly (e.g. seeded entries).
			gc.Country = r.Country
			gc.City = r.City
			gc.Latitude = r.Lat
			gc.Longitude = r.Lng
			gc.Located = true
		} else if loc, ok := geoMap[r.IP]; ok {
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

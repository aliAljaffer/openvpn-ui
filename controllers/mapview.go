package controllers

import (
	"encoding/json"
	"html/template"

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

	clientsJSON, _ := json.Marshal(geoClients)
	c.Data["MapClientsJSON"] = template.JS(clientsJSON)
	c.Data["GeoIPError"] = ""
	c.TplName = "mapview.html"
}

package lib

import (
	"net"
	"strings"

	mi "github.com/d3vilh/openvpn-server-config/server/mi"
	geoip2 "github.com/oschwald/geoip2-golang"
)

// GeoClient wraps an OVClient with geographic coordinates.
type GeoClient struct {
	mi.OVClient
	Latitude  float64
	Longitude float64
	Country   string
	City      string
	Located   bool
}

// EnrichWithGeo looks up each client's real IP in the MaxMind GeoLite2-City
// database at dbPath and returns a slice of GeoClients. Clients whose IP
// cannot be resolved (private ranges, loopback, missing DB record) are
// included with Located=false so they appear in the "unlocated" table.
//
// If the database cannot be opened the error is returned immediately;
// callers should surface it as a non-fatal warning in the UI.
func EnrichWithGeo(clients []*mi.OVClient, dbPath string) ([]GeoClient, error) {
	db, err := geoip2.Open(dbPath)
	if err != nil {
		return nil, err
	}
	defer db.Close()

	result := make([]GeoClient, 0, len(clients))
	for _, c := range clients {
		gc := GeoClient{OVClient: *c}

		// RealAddress may be "ip:port" or "proto:ip:port" (e.g. "tcp4-server:1.2.3.4:5678").
		// The IP is always the second-to-last colon-separated segment.
		parts := strings.Split(c.RealAddress, ":")
		if len(parts) < 2 {
			result = append(result, gc)
			continue
		}
		host := parts[len(parts)-2]

		ip := net.ParseIP(host)
		if ip == nil || ip.IsLoopback() || ip.IsPrivate() {
			result = append(result, gc)
			continue
		}

		record, err := db.City(ip)
		if err != nil || record == nil {
			result = append(result, gc)
			continue
		}

		gc.Latitude = record.Location.Latitude
		gc.Longitude = record.Location.Longitude
		gc.Country = record.Country.Names["en"]
		gc.City = record.City.Names["en"]
		gc.Located = gc.Latitude != 0 || gc.Longitude != 0
		result = append(result, gc)
	}

	return result, nil
}

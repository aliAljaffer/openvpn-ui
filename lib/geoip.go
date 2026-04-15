package lib

import (
	"net"
	"strings"

	mi "github.com/d3vilh/openvpn-server-config/server/mi"
	geoip2 "github.com/oschwald/geoip2-golang"
)

// GeoClient wraps an OVClient with geographic coordinates and optional
// disconnect metadata for recently-disconnected sessions.
type GeoClient struct {
	mi.OVClient
	Latitude       float64
	Longitude      float64
	Country        string
	City           string
	Located        bool
	IsDisconnected bool   // true for recently-disconnected clients (not in MI status)
	DisconnectedAt string // human-readable disconnect time, e.g. "15:04:05"
	Duration       string // session duration, e.g. "23m15s"
}

// GeoLocation holds a resolved geographic position for an IP address.
type GeoLocation struct {
	Country   string
	City      string
	Latitude  float64
	Longitude float64
}

// GeoLookupBatch opens the GeoLite2-City database at dbPath, looks up every IP
// in the ips slice, and returns a map from IP string to GeoLocation.
// IPs that are private, loopback, or not found in the DB are omitted from the map.
// If dbPath is empty or the database cannot be opened the returned map is nil (not an error).
func GeoLookupBatch(dbPath string, ips []string) map[string]GeoLocation {
	if dbPath == "" {
		return nil
	}
	db, err := geoip2.Open(dbPath)
	if err != nil {
		return nil
	}
	defer db.Close()

	result := make(map[string]GeoLocation, len(ips))
	for _, rawIP := range ips {
		ip := net.ParseIP(rawIP)
		if ip == nil || ip.IsLoopback() || ip.IsPrivate() {
			continue
		}
		rec, err := db.City(ip)
		if err != nil || rec == nil {
			continue
		}
		loc := GeoLocation{
			Country:   rec.Country.Names["en"],
			City:      rec.City.Names["en"],
			Latitude:  rec.Location.Latitude,
			Longitude: rec.Location.Longitude,
		}
		if loc.Country == "" && loc.City == "" {
			continue
		}
		result[rawIP] = loc
	}
	return result
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

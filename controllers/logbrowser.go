package controllers

import (
	"encoding/csv"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/beego/beego/v2/core/logs"
	"github.com/beego/beego/v2/server/web"
	"github.com/d3vilh/openvpn-ui/lib"
)

// ArchiveEntry pairs a raw OSS filename with a human-readable display label.
type ArchiveEntry struct {
	Filename string
	Label    string
}

// EventRow is the template-friendly view of an AuditEvent with pre-formatted strings.
type EventRow struct {
	CN             string
	SourceIP       string
	Country        string
	City           string
	ConnectedAt    string
	DisconnectedAt string // empty when session is still active
	Duration       string // empty when session is still active
	IsActive       bool
}

type LogBrowserController struct {
	BaseController
}

func (c *LogBrowserController) NestPrepare() {
	if !c.IsLogin {
		c.Ctx.Redirect(302, c.LoginPath())
		return
	}
	c.Data["breadcrumbs"] = &BreadCrumbs{Title: "Audit Logs"}
}

func (c *LogBrowserController) Get() {
	c.TplName = "logbrowser.html"

	bucket, _ := web.AppConfig.String("OSSLogBucket")
	endpoint, _ := web.AppConfig.String("OSSEndpoint")

	if bucket == "" {
		c.Data["Error"] = "OSSLogBucket is not configured in app.conf."
		return
	}

	archives, err := lib.ListOSSArchives(bucket, endpoint)
	if err != nil {
		logs.Error("LogBrowser: list archives:", err)
		c.Data["Error"] = err.Error()
		return
	}
	c.Data["ArchiveEntries"] = makeArchiveEntries(archives)

	selectedArchive := c.GetString("archive")
	filterCN := c.GetString("cn")

	if selectedArchive == "" && len(archives) > 0 {
		selectedArchive = archives[0] // default to most recent
	}
	c.Data["SelectedArchive"] = selectedArchive
	c.Data["FilterCN"] = filterCN

	if selectedArchive == "" {
		return
	}

	localPath, err := lib.DownloadOSSArchive(bucket, endpoint, selectedArchive, "/tmp")
	if err != nil {
		logs.Error("LogBrowser: download:", err)
		c.Data["Error"] = err.Error()
		return
	}
	defer os.Remove(localPath)

	events, err := lib.ParseLogFile(localPath)
	if err != nil {
		logs.Error("LogBrowser: parse:", err)
		c.Data["Error"] = err.Error()
		return
	}

	// Collect unique CNs for the filter dropdown.
	cnSet := map[string]struct{}{}
	for _, ev := range events {
		cnSet[ev.CN] = struct{}{}
	}
	cnList := make([]string, 0, len(cnSet))
	for cn := range cnSet {
		cnList = append(cnList, cn)
	}
	sort.Strings(cnList)
	c.Data["CNList"] = cnList

	// Geo-enrich all source IPs in one pass (DB opened once).
	dbPath, _ := web.AppConfig.String("GeoipDbPath")
	ips := make([]string, 0, len(events))
	for _, ev := range events {
		ips = append(ips, ev.SourceIP)
	}
	geoMap := lib.GeoLookupBatch(dbPath, ips)

	// Build display rows, applying CN filter.
	const tsFmt = "2006-01-02 15:04:05"
	var rows []EventRow
	for _, ev := range events {
		if filterCN != "" && ev.CN != filterCN {
			continue
		}
		row := EventRow{
			CN:          ev.CN,
			SourceIP:    ev.SourceIP,
			ConnectedAt: ev.ConnectTime.Format(tsFmt),
			IsActive:    ev.DisconnectTime.IsZero(),
			Duration:    ev.Duration,
		}
		if loc, ok := geoMap[ev.SourceIP]; ok {
			row.Country = loc.Country
			row.City = loc.City
		}
		if !ev.DisconnectTime.IsZero() {
			row.DisconnectedAt = ev.DisconnectTime.Format(tsFmt)
		}
		rows = append(rows, row)
	}
	c.Data["Events"] = rows
}

func (c *LogBrowserController) Export() {
	bucket, _ := web.AppConfig.String("OSSLogBucket")
	endpoint, _ := web.AppConfig.String("OSSEndpoint")
	archive := c.GetString("archive")
	filterCN := c.GetString("cn")

	if bucket == "" || archive == "" {
		c.Ctx.WriteString("Missing bucket configuration or archive parameter.")
		return
	}

	localPath, err := lib.DownloadOSSArchive(bucket, endpoint, archive, "/tmp")
	if err != nil {
		logs.Error("LogBrowser Export: download:", err)
		c.Ctx.WriteString("Download failed: " + err.Error())
		return
	}
	defer os.Remove(localPath)

	events, err := lib.ParseLogFile(localPath)
	if err != nil {
		logs.Error("LogBrowser Export: parse:", err)
		c.Ctx.WriteString("Parse failed: " + err.Error())
		return
	}

	dbPath, _ := web.AppConfig.String("GeoipDbPath")
	ips := make([]string, 0, len(events))
	for _, ev := range events {
		ips = append(ips, ev.SourceIP)
	}
	geoMap := lib.GeoLookupBatch(dbPath, ips)

	filename := strings.TrimSuffix(filepath.Base(archive), ".gz")
	c.Ctx.Output.Header("Content-Type", "text/csv; charset=utf-8")
	c.Ctx.Output.Header("Content-Disposition",
		fmt.Sprintf(`attachment; filename="%s"`, filename))

	const tsFmt = "2006-01-02 15:04:05"
	w := csv.NewWriter(c.Ctx.ResponseWriter)
	_ = w.Write([]string{"User CN", "Source IP", "Country", "City", "Connect Time", "Disconnect Time", "Duration"})
	for _, ev := range events {
		if filterCN != "" && ev.CN != filterCN {
			continue
		}
		discStr := ""
		if !ev.DisconnectTime.IsZero() {
			discStr = ev.DisconnectTime.Format(tsFmt)
		}
		country, city := "", ""
		if loc, ok := geoMap[ev.SourceIP]; ok {
			country, city = loc.Country, loc.City
		}
		_ = w.Write([]string{
			ev.CN,
			ev.SourceIP,
			country,
			city,
			ev.ConnectTime.Format(tsFmt),
			discStr,
			ev.Duration,
		})
	}
	w.Flush()
}

// makeArchiveEntries converts raw OSS filenames into display-friendly entries.
// "openvpn-logs-2024-04-14-235959.log.gz" → label "2024-04-14 23:59:59"
func makeArchiveEntries(filenames []string) []ArchiveEntry {
	entries := make([]ArchiveEntry, 0, len(filenames))
	for _, name := range filenames {
		label := strings.TrimPrefix(name, "openvpn-logs-")
		label = strings.TrimSuffix(label, ".log.gz")
		// "YYYY-MM-DD-HHmmss" is 17 chars; reformat to "YYYY-MM-DD HH:mm:ss"
		if len(label) == 17 {
			label = label[:10] + " " + label[11:13] + ":" + label[13:15] + ":" + label[15:17]
		}
		entries = append(entries, ArchiveEntry{Filename: name, Label: label})
	}
	return entries
}

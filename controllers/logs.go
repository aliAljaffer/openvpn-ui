package controllers

import (
	"bufio"
	"os/exec"
	"strings"

	"github.com/beego/beego/v2/core/logs"
)

type LogsController struct {
	BaseController
}

func (c *LogsController) NestPrepare() {
	if !c.IsLogin {
		c.Ctx.Redirect(302, c.LoginPath())
		return
	}
}

func (c *LogsController) Get() {
	c.TplName = "logs.html"
	c.Data["breadcrumbs"] = &BreadCrumbs{
		Title: "Logs",
	}

	// Run /opt/scripts/logs.sh which is mounted from the host and calls
	// journalctl -n 300 -xeu openvpn-server@server.service --no-pager
	out, err := exec.Command("/opt/scripts/logs.sh").Output()
	if err != nil {
		logs.Error("logs.sh failed:", err)
		c.Data["logs"] = []string{"Could not read logs: " + err.Error()}
		return
	}

	var lines []string
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.Contains(line, " MANAGEMENT: ") {
			lines = append(lines, strings.TrimSpace(line))
		}
	}
	c.Data["logs"] = lines
}

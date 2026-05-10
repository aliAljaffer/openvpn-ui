package controllers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os/exec"
	"strconv"
	"strings"

	"github.com/beego/beego/v2/core/logs"
	"github.com/beego/beego/v2/server/web"
	"github.com/d3vilh/openvpn-ui/models"
)

// PortForwardController exposes /opt/scripts/port-forward.sh as a UI.
// The script is the single source of truth for iptables manipulation; this
// controller is a thin wrapper that shells out to it.
type PortForwardController struct {
	BaseController
}

const portForwardScript = "/opt/scripts/port-forward.sh"

// PortForwardRule mirrors the JSON shape emitted by `port-forward.sh list --format json`.
type PortForwardRule struct {
	ListenPort int    `json:"listen_port"`
	DestIP     string `json:"dest_ip"`
	DestPort   int    `json:"dest_port"`
}

type portForwardListPayload struct {
	IPForward int               `json:"ip_forward"`
	Rules     []PortForwardRule `json:"rules"`
}

func (c *PortForwardController) NestPrepare() {
	if !c.IsLogin {
		c.Ctx.Redirect(302, c.LoginPath())
		return
	}
	c.Data["breadcrumbs"] = &BreadCrumbs{
		Title: "Port forwarding",
	}
}

// @router /portforward [get]
func (c *PortForwardController) Get() {
	c.TplName = "portforward.html"
	c.render()
}

// @router /portforward [post]
func (c *PortForwardController) Post() {
	c.TplName = "portforward.html"
	flash := web.NewFlash()

	listenPort, errLP := strconv.Atoi(strings.TrimSpace(c.GetString("listen_port")))
	destIP := strings.TrimSpace(c.GetString("dest_ip"))
	destPort, errDP := strconv.Atoi(strings.TrimSpace(c.GetString("dest_port")))

	switch {
	case errLP != nil || listenPort < 1 || listenPort > 65535:
		flash.Error("Listen port must be an integer between 1 and 65535.")
	case errDP != nil || destPort < 1 || destPort > 65535:
		flash.Error("Destination port must be an integer between 1 and 65535.")
	case net.ParseIP(destIP) == nil || strings.Contains(destIP, ":"):
		flash.Error("Destination IP must be a valid IPv4 address.")
	default:
		if reason := reservedListenPort(listenPort); reason != "" {
			flash.Error(fmt.Sprintf("Listen port %d is reserved (%s). Pick a different port.", listenPort, reason))
		} else {
			out, err := runPortForward("add", strconv.Itoa(listenPort), destIP, strconv.Itoa(destPort))
			if err != nil {
				logs.Error("port-forward add failed:", err, "output:", out)
				flash.Error(scriptErrorMessage(out, err))
			} else {
				flash.Success(fmt.Sprintf("Forwarding tcp/%d → %s:%d configured.", listenPort, destIP, destPort))
			}
		}
	}

	flash.Store(&c.Controller)
	c.Redirect(c.URLFor("PortForwardController.Get"), 302)
}

// @router /portforward/delete [post]
func (c *PortForwardController) Delete() {
	flash := web.NewFlash()
	listenPort, err := strconv.Atoi(strings.TrimSpace(c.GetString("listen_port")))
	if err != nil || listenPort < 1 || listenPort > 65535 {
		flash.Error("Invalid listen port.")
		flash.Store(&c.Controller)
		c.Redirect(c.URLFor("PortForwardController.Get"), 302)
		return
	}

	out, err := runPortForward("remove", strconv.Itoa(listenPort))
	if err != nil {
		logs.Error("port-forward remove failed:", err, "output:", out)
		flash.Error(scriptErrorMessage(out, err))
	} else {
		flash.Success(fmt.Sprintf("Forwarding rule on tcp/%d removed.", listenPort))
	}
	flash.Store(&c.Controller)
	c.Redirect(c.URLFor("PortForwardController.Get"), 302)
}

func (c *PortForwardController) render() {
	rules, ipForward, listErr := listRules()
	if listErr != nil {
		// Surface as a flash without overwriting any flash already stored
		// by Post/Delete redirects (Beego's flash mechanism is one-shot).
		logs.Error("port-forward list failed:", listErr)
		c.Data["ListError"] = listErr.Error()
	}

	c.Data["Rules"] = rules
	c.Data["IPForward"] = ipForward
	c.Data["ReservedPorts"] = reservedPortSummary()
	c.Data["OpenVPNPort"] = openVPNServerPort()
}

func listRules() ([]PortForwardRule, int, error) {
	out, err := runPortForward("list", "--format", "json")
	if err != nil {
		return nil, 0, fmt.Errorf("%s: %s", err, scriptErrorMessage(out, err))
	}
	var p portForwardListPayload
	if jsonErr := json.Unmarshal([]byte(out), &p); jsonErr != nil {
		return nil, 0, fmt.Errorf("could not parse port-forward output: %v", jsonErr)
	}
	return p.Rules, p.IPForward, nil
}

func runPortForward(args ...string) (string, error) {
	cmd := exec.Command(portForwardScript, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		// Return whatever the script wrote so the caller can surface it verbatim.
		combined := strings.TrimSpace(stdout.String() + "\n" + stderr.String())
		return combined, err
	}
	return stdout.String(), nil
}

// scriptErrorMessage extracts a useful one-liner from the script's combined
// output (stderr + stdout) for display in a flash message.
func scriptErrorMessage(out string, err error) string {
	out = strings.TrimSpace(out)
	if out == "" {
		return err.Error()
	}
	// The script prefixes errors with "[ERROR]" — pull the last such line.
	for _, line := range reverseLines(strings.Split(out, "\n")) {
		if strings.Contains(line, "[ERROR]") {
			return strings.TrimSpace(strings.SplitN(line, "[ERROR]", 2)[1])
		}
	}
	// Fallback: last non-empty line.
	for _, line := range reverseLines(strings.Split(out, "\n")) {
		line = strings.TrimSpace(line)
		if line != "" {
			return line
		}
	}
	return err.Error()
}

func reverseLines(lines []string) []string {
	out := make([]string, len(lines))
	for i, l := range lines {
		out[len(lines)-1-i] = l
	}
	return out
}

// reservedListenPort returns a human-readable reason if the port is
// disallowed by the UI, or "" if it can be used. The CLI remains permissive —
// this is a UI-only guardrail per the Phase 3 plan.
func reservedListenPort(p int) string {
	switch p {
	case 22:
		return "SSH"
	case 8080:
		return "openvpn-ui HTTP"
	case 8443:
		return "openvpn-ui HTTPS"
	}
	if vpn := openVPNServerPort(); vpn > 0 && p == vpn {
		return fmt.Sprintf("OpenVPN server (%d)", vpn)
	}
	if p < 2000 {
		return "well-known / system port (<2000)"
	}
	return ""
}

func reservedPortSummary() string {
	parts := []string{"22 (SSH)", "8080 (UI HTTP)", "8443 (UI HTTPS)", "all ports below 2000"}
	if vpn := openVPNServerPort(); vpn > 0 && vpn >= 2000 {
		parts = append(parts, fmt.Sprintf("%d (OpenVPN)", vpn))
	}
	return strings.Join(parts, ", ")
}

// openVPNServerPort returns the configured OpenVPN port, or 0 if unavailable.
func openVPNServerPort() int {
	cfg := models.OVConfig{Profile: "default"}
	if err := cfg.Read("Profile"); err != nil {
		// Fall back to the value stored in app.conf if the DB row isn't readable.
		if v, perr := web.AppConfig.Int("OpenVpnServerPort"); perr == nil {
			return v
		}
		return 0
	}
	return cfg.Port
}

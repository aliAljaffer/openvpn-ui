# Stage 1: compile openvpn-ui with geoip2 support
FROM golang:1.25-bookworm AS builder
WORKDIR /go/src/github.com/d3vilh/openvpn-ui
COPY . .
RUN apt-get update -qq && apt-get install -y --no-install-recommends gcc musl-tools
RUN go install github.com/beego/bee/v2@develop
RUN go env -w GOFLAGS="-buildvcs=false"
RUN go mod download && go mod vendor
ENV CGO_ENABLED=1 CC=musl-gcc GO111MODULE=auto
RUN bee pack -exr='^vendor|^ace.tar.bz2|^data.db|^build|^README.md|^docs'

# Stage 2: runtime image (Alpine)
FROM alpine:3.19
# iptables is required for the port-forwarding controller, which shells out to
# /opt/scripts/port-forward.sh (NAT rule management). The container also needs
# cap_add: NET_ADMIN at runtime — see host/setup.sh write_compose().
RUN apk add --no-cache bash easy-rsa curl jq oath-toolkit-oathtool iptables
WORKDIR /opt
COPY build/assets/start.sh /opt/start.sh
RUN chmod +x /opt/start.sh && mkdir -p /opt/openvpn-ui
COPY --from=builder /go/src/github.com/d3vilh/openvpn-ui/openvpn-ui.tar.gz /tmp/openvpn-ui.tar.gz
RUN tar -xzf /tmp/openvpn-ui.tar.gz -C /opt/openvpn-ui/ && rm /tmp/openvpn-ui.tar.gz
EXPOSE 8080/tcp 8443/tcp
CMD ["/opt/start.sh"]

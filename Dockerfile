# Stage 1: compile openvpn-ui with geoip2 support
FROM golang:1.23.4-bookworm AS builder
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
RUN apk add --no-cache bash easy-rsa curl jq oath-toolkit-oathtool
WORKDIR /opt
COPY build/assets/start.sh /opt/start.sh
RUN chmod +x /opt/start.sh && mkdir -p /opt/openvpn-ui
COPY --from=builder /go/src/github.com/d3vilh/openvpn-ui/openvpn-ui.tar.gz /tmp/openvpn-ui.tar.gz
RUN tar -xzf /tmp/openvpn-ui.tar.gz -C /opt/openvpn-ui/ && rm /tmp/openvpn-ui.tar.gz
EXPOSE 8080/tcp 8443/tcp
CMD ["/opt/start.sh"]

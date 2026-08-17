#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULTS=/etc/default/vps-psiphon
SERVICE=/etc/systemd/system/vps-psiphon.service
FW_SERVICE=/etc/systemd/system/vps-psiphon-firewall.service
RUNNER=/usr/local/sbin/vps-psiphon-run
FIREWALL=/usr/local/sbin/vps-psiphon-firewall
CLI=/usr/local/bin/vps-psiphon

die() { echo "vps-psiphon: ERROR: $*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: psiphon_install.sh [options]
  --region CC          set device and egress region
  --device-region CC   set device region
  --egress-region CC   set egress region
  --socks-port PORT    SOCKS TCP port (default: 1080)
  --http-port PORT     HTTP TCP port (default: 8080)
  --publish-http 0|1   compatibility setting (default: 0; firewall always blocks externally)
  --image IMAGE        container image
EOF
}

[ "${EUID:-$(id -u)}" -eq 0 ] || die "run as root"
for command in docker systemctl curl ss nft; do
  command -v "$command" >/dev/null || die "$command is required"
done

IMAGE=ghcr.io/charafreedom/psiphon:latest
SOCKS_PORT=1080
HTTP_PORT=8080
DEVICE_REGION=
EGRESS_REGION=
PUBLISH_HTTP=0
CONF_DIR=/var/lib/vps-psiphon
if [ -r "$DEFAULTS" ]; then
  # shellcheck disable=SC1090
  . "$DEFAULTS"
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --region) DEVICE_REGION=${2:?}; EGRESS_REGION=$2; shift 2 ;;
    --device-region) DEVICE_REGION=${2:?}; shift 2 ;;
    --egress-region) EGRESS_REGION=${2:?}; shift 2 ;;
    --socks-port) SOCKS_PORT=${2:?}; shift 2 ;;
    --http-port) HTTP_PORT=${2:?}; shift 2 ;;
    --publish-http) PUBLISH_HTTP=${2:?}; shift 2 ;;
    --image) IMAGE=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_port "$SOCKS_PORT" || die "invalid SOCKS port: $SOCKS_PORT"
valid_port "$HTTP_PORT" || die "invalid HTTP port: $HTTP_PORT"
[ "$SOCKS_PORT" != "$HTTP_PORT" ] || die "SOCKS and HTTP ports must differ"
[[ $PUBLISH_HTTP == 0 || $PUBLISH_HTTP == 1 ]] || die "--publish-http must be 0 or 1"

# An upgrade must remove the old bridge container before checking host ports.
systemctl stop vps-psiphon.service 2>/dev/null || true
docker rm -f vps-psiphon >/dev/null 2>&1 || true
port_busy() { ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }
port_busy "$SOCKS_PORT" && die "TCP port $SOCKS_PORT is already in use"
port_busy "$HTTP_PORT" && die "TCP port $HTTP_PORT is already in use"

install -d -m 0755 "$CONF_DIR" /etc/default
cat >"$DEFAULTS" <<EOF
IMAGE=$(printf '%q' "$IMAGE")
SOCKS_PORT=$SOCKS_PORT
HTTP_PORT=$HTTP_PORT
DEVICE_REGION=$(printf '%q' "$DEVICE_REGION")
EGRESS_REGION=$(printf '%q' "$EGRESS_REGION")
PUBLISH_HTTP=$PUBLISH_HTTP
CONF_DIR=$(printf '%q' "$CONF_DIR")
EOF
chmod 0644 "$DEFAULTS"

cat >"$RUNNER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/default/vps-psiphon
NAME=vps-psiphon
# Defence in depth: a manual service restart must not expose a host listener if
# somebody removed or changed the nftables table after boot.
rules=$(nft list table inet psiphon_guard 2>/dev/null) || {
  echo "vps-psiphon: firewall guard is missing; refusing to start" >&2
  exit 1
}
[[ $rules == *'iifname != "lo"'*"dport $SOCKS_PORT drop"* && \
   $rules == *'iifname != "lo"'*"dport $HTTP_PORT drop"* ]] || {
  echo "vps-psiphon: firewall guard is incomplete; refusing to start" >&2
  exit 1
}
exec docker run --rm --name "$NAME" \
  --network host \
  -e PUID=1000 -e PGID=1000 \
  -e SOCKS_PORT="$SOCKS_PORT" -e HTTP_PORT="$HTTP_PORT" \
  -e DEVICE_REGION="$DEVICE_REGION" -e EGRESS_REGION="$EGRESS_REGION" \
  -v "${CONF_DIR}:/config" \
  "$IMAGE"
EOF
chmod 0755 "$RUNNER"

cat >"$FIREWALL" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/default/vps-psiphon
[[ $SOCKS_PORT =~ ^[0-9]+$ ]] && (( SOCKS_PORT >= 1 && SOCKS_PORT <= 65535 ))
[[ $HTTP_PORT =~ ^[0-9]+$ ]] && (( HTTP_PORT >= 1 && HTTP_PORT <= 65535 ))
nft list table inet psiphon_guard >/dev/null 2>&1 && nft delete table inet psiphon_guard
nft add table inet psiphon_guard
nft 'add chain inet psiphon_guard input { type filter hook input priority -50; policy accept; }'
nft add rule inet psiphon_guard input iifname '!=' lo tcp dport "$SOCKS_PORT" drop
# The image may listen even when its HTTP proxy is not advertised, so always guard it.
nft add rule inet psiphon_guard input iifname '!=' lo tcp dport "$HTTP_PORT" drop
nft list table inet psiphon_guard >/dev/null
EOF
chmod 0755 "$FIREWALL"

cat >"$FW_SERVICE" <<EOF
[Unit]
Description=vps-psiphon firewall guard
Before=vps-psiphon.service
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=$FIREWALL
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat >"$SERVICE" <<EOF
[Unit]
Description=Psiphon proxy container
Requires=vps-psiphon-firewall.service docker.service
After=vps-psiphon-firewall.service docker.service

[Service]
ExecStart=$RUNNER
ExecStop=-/usr/bin/docker stop vps-psiphon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat >"$CLI" <<'EOF'
#!/usr/bin/env bash
set -u
. /etc/default/vps-psiphon
case "${1:-status}" in
  status)
    state=$(systemctl is-active vps-psiphon.service 2>/dev/null || true)
    printf 'service   : %s\nnetwork   : host\n' "${state:-inactive}"
    rules=$(nft list table inet psiphon_guard 2>/dev/null || true)
    if [[ $rules == *'iifname != "lo"'*"dport $SOCKS_PORT drop"* && \
          $rules == *'iifname != "lo"'*"dport $HTTP_PORT drop"* ]]; then
      printf 'firewall  : active\nsocks     : 127.0.0.1:%s (externally blocked)\nhttp      : 127.0.0.1:%s (externally blocked)\n' "$SOCKS_PORT" "$HTTP_PORT"
    else
      printf 'firewall  : MISSING — SOCKS MAY BE PUBLIC\nsocks     : 127.0.0.1:%s (UNSAFE)\n' "$SOCKS_PORT"
      exit 1
    fi
    ;;
  logs) exec docker logs "${@:2}" vps-psiphon ;;
  restart) exec systemctl restart vps-psiphon.service ;;
  uninstall)
    systemctl disable --now vps-psiphon.service 2>/dev/null || true
    systemctl disable --now vps-psiphon-firewall.service 2>/dev/null || true
    docker rm -f vps-psiphon >/dev/null 2>&1 || true
    nft delete table inet psiphon_guard 2>/dev/null || true
    rm -f /etc/systemd/system/vps-psiphon.service /etc/systemd/system/vps-psiphon-firewall.service
    rm -f /usr/local/sbin/vps-psiphon-run /usr/local/sbin/vps-psiphon-firewall /etc/default/vps-psiphon
    rm -f /usr/local/bin/vps-psiphon
    systemctl daemon-reload
    echo 'vps-psiphon uninstalled (configuration remains in /var/lib/vps-psiphon)'
    ;;
  *) echo "Usage: vps-psiphon {status|logs|restart|uninstall}" >&2; exit 2 ;;
esac
EOF
chmod 0755 "$CLI"

systemctl daemon-reload
systemctl enable vps-psiphon-firewall.service vps-psiphon.service >/dev/null
# A failed guard aborts here. The host-network container has not been started yet.
systemctl restart vps-psiphon-firewall.service
nft list table inet psiphon_guard >/dev/null || die "firewall verification failed; refusing to start Psiphon"
systemctl restart vps-psiphon.service

echo "Waiting for the SOCKS endpoint..."
exit_ip=
for _ in $(seq 1 12); do
  if exit_ip=$(curl -fsS --socks5-hostname "127.0.0.1:$SOCKS_PORT" --max-time 20 https://api.ipify.org); then break; fi
  sleep 5
done
if [ -z "$exit_ip" ]; then
  echo "SOCKS health check failed. Diagnostics:" >&2
  docker logs --tail 100 vps-psiphon >&2 || true
  systemctl --no-pager --full status vps-psiphon.service >&2 || true
  nft list table inet psiphon_guard >&2 || true
  exit 1
fi
network=$(docker inspect vps-psiphon --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)
[ "$network" = host ] || die "container network verification failed"
printf '\nPsiphon is ready (exit IP: %s)\n' "$exit_ip"
printf 'SOCKS listener: *:%s\nExternal access: blocked by nftables\nLocal endpoint: 127.0.0.1:%s\n' "$SOCKS_PORT" "$SOCKS_PORT"
printf 'Xray outbound: {"tag":"psiphon-out","protocol":"socks","settings":{"address":"127.0.0.1","port":%s}}\n' "$SOCKS_PORT"

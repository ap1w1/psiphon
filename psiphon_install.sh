#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULTS=/etc/default/vps-psiphon
SERVICE=/etc/systemd/system/vps-psiphon.service
FW_SERVICE=/etc/systemd/system/vps-psiphon-firewall.service
RUNNER=/usr/local/sbin/vps-psiphon-run
FIREWALL=/usr/local/sbin/vps-psiphon-firewall
CLI=/usr/local/bin/vps-psiphon
OLD_CLI=/usr/local/sbin/vps-psiphon

die() {
  echo "vps-psiphon: ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: psiphon_install.sh [options]

  --region CC          set Psiphon egress region
  --device-region CC   set device region
  --egress-region CC   set egress region
  --socks-port PORT    SOCKS TCP port (default: 1080)
  --http-port PORT     HTTP TCP port (default: 8080)
  --publish-http 0|1   compatibility setting (default: 0)
  --image IMAGE        container image
  -h, --help           show help
EOF
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

[ "${EUID:-$(id -u)}" -eq 0 ] || die "run as root"

for command in docker systemctl curl ss nft grep seq; do
  command -v "$command" >/dev/null || die "$command is required"
done

docker info >/dev/null 2>&1 || die "docker daemon is not running"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

SOCKS_PORT=1080
HTTP_PORT=8080
DEVICE_REGION=
EGRESS_REGION=
PUBLISH_HTTP=0
CONF_DIR=/var/lib/vps-psiphon

# Preserve existing settings on reinstall.
if [ -r "$DEFAULTS" ]; then
  # shellcheck disable=SC1090
  . "$DEFAULTS"
fi

# Do not inherit obsolete image values from older installations.
IMAGE=swarupsengupta2007/psiphon:latest

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    --region)
      EGRESS_REGION=${2:?}
      shift 2
      ;;
    --device-region)
      DEVICE_REGION=${2:?}
      shift 2
      ;;
    --egress-region)
      EGRESS_REGION=${2:?}
      shift 2
      ;;
    --socks-port)
      SOCKS_PORT=${2:?}
      shift 2
      ;;
    --http-port)
      HTTP_PORT=${2:?}
      shift 2
      ;;
    --publish-http)
      PUBLISH_HTTP=${2:?}
      shift 2
      ;;
    --image)
      IMAGE=${2:?}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

valid_port "$SOCKS_PORT" || die "invalid SOCKS port: $SOCKS_PORT"
valid_port "$HTTP_PORT" || die "invalid HTTP port: $HTTP_PORT"

[ "$SOCKS_PORT" != "$HTTP_PORT" ] ||
  die "SOCKS and HTTP ports must differ"

[[ $PUBLISH_HTTP == 0 || $PUBLISH_HTTP == 1 ]] ||
  die "--publish-http must be 0 or 1"

# ---------------------------------------------------------------------------
# Stop old installation before port checks
# ---------------------------------------------------------------------------

systemctl stop vps-psiphon.service 2>/dev/null || true
docker rm -f vps-psiphon >/dev/null 2>&1 || true

port_busy() {
  ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .
}

port_busy "$SOCKS_PORT" &&
  die "TCP port $SOCKS_PORT is already in use"

port_busy "$HTTP_PORT" &&
  die "TCP port $HTTP_PORT is already in use"

# ---------------------------------------------------------------------------
# Pull image first
# ---------------------------------------------------------------------------

echo "Pulling image: $IMAGE"
docker pull "$IMAGE" >/dev/null ||
  die "cannot pull image: $IMAGE"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Container launcher
# ---------------------------------------------------------------------------

cat >"$RUNNER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

. /etc/default/vps-psiphon

NAME=vps-psiphon

# Fail closed: never start a host-network SOCKS proxy without the guard.
rules=$(nft list table inet psiphon_guard 2>/dev/null) || {
  echo "vps-psiphon: firewall guard is missing; refusing to start" >&2
  exit 1
}

[[ $rules == *'iifname != "lo"'*"dport $SOCKS_PORT drop"* && \
   $rules == *'iifname != "lo"'*"dport $HTTP_PORT drop"* ]] || {
  echo "vps-psiphon: firewall guard is incomplete; refusing to start" >&2
  exit 1
}

exec docker run \
  --rm \
  --name "$NAME" \
  --network host \
  -e PUID=1000 \
  -e PGID=1000 \
  -e SOCKS_PORT="$SOCKS_PORT" \
  -e HTTP_PORT="$HTTP_PORT" \
  -e DEVICE_REGION="$DEVICE_REGION" \
  -e EGRESS_REGION="$EGRESS_REGION" \
  -v "${CONF_DIR}:/config" \
  "$IMAGE"
EOF

chmod 0755 "$RUNNER"

# ---------------------------------------------------------------------------
# Firewall guard
# ---------------------------------------------------------------------------

cat >"$FIREWALL" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

. /etc/default/vps-psiphon

[[ $SOCKS_PORT =~ ^[0-9]+$ ]] &&
  (( SOCKS_PORT >= 1 && SOCKS_PORT <= 65535 ))

[[ $HTTP_PORT =~ ^[0-9]+$ ]] &&
  (( HTTP_PORT >= 1 && HTTP_PORT <= 65535 ))

# Recreate atomically enough for our service lifecycle:
# the Psiphon service is stopped before this runs.
nft list table inet psiphon_guard >/dev/null 2>&1 &&
  nft delete table inet psiphon_guard

nft add table inet psiphon_guard

nft 'add chain inet psiphon_guard input {
  type filter hook input priority -50;
  policy accept;
}'

# Psiphon listens on all host interfaces in --network host mode.
# Only loopback may access these ports.
nft add rule inet psiphon_guard input \
  iifname '!=' lo \
  tcp dport "$SOCKS_PORT" \
  drop

# Guard HTTP too because the image may listen even when HTTP is not advertised.
nft add rule inet psiphon_guard input \
  iifname '!=' lo \
  tcp dport "$HTTP_PORT" \
  drop

nft list table inet psiphon_guard >/dev/null
EOF

chmod 0755 "$FIREWALL"

# ---------------------------------------------------------------------------
# systemd firewall service
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# systemd Psiphon service
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

rm -f "$OLD_CLI"

cat >"$CLI" <<'EOF'
#!/usr/bin/env bash
set -u

. /etc/default/vps-psiphon

case "${1:-status}" in
  status)
    state=$(systemctl is-active vps-psiphon.service 2>/dev/null || true)

    printf 'service   : %s\n' "${state:-inactive}"
    printf 'network   : host\n'

    rules=$(nft list table inet psiphon_guard 2>/dev/null || true)

    if [[ $rules == *'iifname != "lo"'*"dport $SOCKS_PORT drop"* && \
          $rules == *'iifname != "lo"'*"dport $HTTP_PORT drop"* ]]; then
      printf 'firewall  : active\n'
      printf 'socks     : 127.0.0.1:%s (externally blocked)\n' "$SOCKS_PORT"
      printf 'http      : 127.0.0.1:%s (externally blocked)\n' "$HTTP_PORT"
    else
      printf 'firewall  : MISSING — SOCKS MAY BE PUBLIC\n'
      printf 'socks     : 127.0.0.1:%s (UNSAFE)\n' "$SOCKS_PORT"
      exit 1
    fi

    if docker inspect vps-psiphon >/dev/null 2>&1; then
      network=$(
        docker inspect vps-psiphon \
          --format '{{.HostConfig.NetworkMode}}' \
          2>/dev/null || true
      )

      image=$(
        docker inspect vps-psiphon \
          --format '{{.Config.Image}}' \
          2>/dev/null || true
      )

      printf 'docker    : %s\n' "${network:-unknown}"
      printf 'image     : %s\n' "${image:-unknown}"
    fi

    exit_ip=$(
      curl -fsS \
        --socks5-hostname "127.0.0.1:$SOCKS_PORT" \
        --connect-timeout 5 \
        --max-time 15 \
        https://ifconfig.me \
        2>/dev/null || true
    )

    printf 'exit IP   : %s\n' "${exit_ip:-UNREACHABLE}"
    ;;

  logs)
    shift
    exec docker logs "$@" vps-psiphon
    ;;

  restart)
    exec systemctl restart vps-psiphon.service
    ;;

  uninstall)
    systemctl disable --now vps-psiphon.service 2>/dev/null || true
    systemctl disable --now vps-psiphon-firewall.service 2>/dev/null || true

    docker rm -f vps-psiphon >/dev/null 2>&1 || true

    nft delete table inet psiphon_guard 2>/dev/null || true

    rm -f \
      /etc/systemd/system/vps-psiphon.service \
      /etc/systemd/system/vps-psiphon-firewall.service \
      /usr/local/sbin/vps-psiphon-run \
      /usr/local/sbin/vps-psiphon-firewall \
      /usr/local/sbin/vps-psiphon \
      /usr/local/bin/vps-psiphon \
      /etc/default/vps-psiphon

    systemctl daemon-reload

    echo "vps-psiphon uninstalled"
    echo "configuration remains in /var/lib/vps-psiphon"
    ;;

  *)
    echo "Usage: vps-psiphon {status|logs|restart|uninstall}" >&2
    exit 2
    ;;
esac
EOF

chmod 0755 "$CLI"

# Compatibility with old installations / cached shell command path.
ln -sf "$CLI" "$OLD_CLI"

# ---------------------------------------------------------------------------
# Enable services
# ---------------------------------------------------------------------------

systemctl daemon-reload

systemctl enable \
  vps-psiphon-firewall.service \
  vps-psiphon.service \
  >/dev/null

# Never start Psiphon unless firewall creation succeeds.
systemctl restart vps-psiphon-firewall.service

nft list table inet psiphon_guard >/dev/null ||
  die "firewall verification failed; refusing to start Psiphon"

systemctl restart vps-psiphon.service

# ---------------------------------------------------------------------------
# Wait for listener
# ---------------------------------------------------------------------------

echo "Waiting for the SOCKS listener..."

listener_ready=0

for _ in $(seq 1 30); do
  if ss -H -ltn "sport = :$SOCKS_PORT" 2>/dev/null | grep -q .; then
    listener_ready=1
    break
  fi

  sleep 1
done

if [ "$listener_ready" != 1 ]; then
  echo "SOCKS listener did not start. Diagnostics:" >&2

  systemctl --no-pager --full status \
    vps-psiphon.service >&2 || true

  journalctl \
    -u vps-psiphon.service \
    -n 100 \
    --no-pager >&2 || true

  nft list table inet psiphon_guard >&2 || true

  exit 1
fi

# ---------------------------------------------------------------------------
# Wait for functional Psiphon tunnel
# ---------------------------------------------------------------------------

echo "SOCKS listener is up; waiting for the Psiphon tunnel..."

ready=0

for _ in $(seq 1 30); do
  code=$(
    curl -s \
      --socks5-hostname "127.0.0.1:$SOCKS_PORT" \
      --connect-timeout 5 \
      --max-time 15 \
      -o /dev/null \
      -w '%{http_code}' \
      https://www.gstatic.com/generate_204 \
      2>/dev/null || true
  )

  if [ "$code" = "204" ]; then
    ready=1
    break
  fi

  sleep 5
done

if [ "$ready" != 1 ]; then
  echo "Psiphon tunnel did not become ready. Diagnostics:" >&2

  docker logs \
    --tail 100 \
    vps-psiphon >&2 || true

  systemctl --no-pager --full status \
    vps-psiphon.service >&2 || true

  nft list table inet psiphon_guard >&2 || true

  exit 1
fi

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------

network=$(
  docker inspect vps-psiphon \
    --format '{{.HostConfig.NetworkMode}}' \
    2>/dev/null || true
)

[ "$network" = host ] ||
  die "container network verification failed"

rules=$(nft list table inet psiphon_guard 2>/dev/null) ||
  die "firewall disappeared after Psiphon startup"

[[ $rules == *'iifname != "lo"'*"dport $SOCKS_PORT drop"* && \
   $rules == *'iifname != "lo"'*"dport $HTTP_PORT drop"* ]] ||
  die "firewall verification failed after Psiphon startup"

exit_ip=$(
  curl -fsS \
    --socks5-hostname "127.0.0.1:$SOCKS_PORT" \
    --connect-timeout 5 \
    --max-time 15 \
    https://ifconfig.me \
    2>/dev/null || true
)

[ -n "$exit_ip" ] || exit_ip="unknown"

printf '\nPsiphon is ready (exit IP: %s)\n' "$exit_ip"
printf 'Network mode: host\n'
printf 'SOCKS listener: *:%s\n' "$SOCKS_PORT"
printf 'HTTP listener: *:%s\n' "$HTTP_PORT"
printf 'External access: blocked by nftables\n'
printf 'Local SOCKS endpoint: 127.0.0.1:%s\n' "$SOCKS_PORT"

printf '\nXray outbound:\n'
printf '{"tag":"psiphon-out","protocol":"socks","settings":{"address":"127.0.0.1","port":%s}}\n' \
  "$SOCKS_PORT"

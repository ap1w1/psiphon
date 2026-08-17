# vps-psiphon

Run Psiphon as a local, TCP-only SOCKS proxy for Xray/Remnawave on Debian or Ubuntu.

## Installation

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ap1w1/vps-psiphon/main/psiphon_install.sh)
```

Choose a region or custom ports in the same command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ap1w1/vps-psiphon/main/psiphon_install.sh) --region DE
bash <(curl -fsSL https://raw.githubusercontent.com/ap1w1/vps-psiphon/main/psiphon_install.sh) --socks-port 1180 --http-port 8180
```

Other custom settings are `--device-region CC`, `--egress-region CC`, `--image IMAGE`, and
`--publish-http 0|1`. HTTP publication defaults to `0`. Run with `--help` for the complete list.
Existing settings in `/etc/default/vps-psiphon` are retained on upgrade unless overridden.

The installer requires root, Docker, curl, iproute2 (`ss`), systemd, and nftables. It stops and
removes an old container, checks that both host ports are free, installs and verifies the firewall,
starts the container, then performs a SOCKS health check. No manual firewall or launcher edits are
required.

## Network and security model

Psiphon runs with Docker `--network host`; Docker bridge networking and `-p` publishing are not
used. The process therefore listens in the host network namespace (and may appear as `*:1080` and
`*:8080` in `ss`). A dedicated `inet psiphon_guard` nftables table drops TCP traffic to both configured
ports arriving on every interface except loopback. Local clients use `127.0.0.1:1080`; the VPS public
IP cannot use either proxy port.

The firewall is installed and successfully verified **before** the host-network container can start.
The Psiphon service requires `vps-psiphon-firewall.service`, and both services are enabled across
reboots. The guard has its own table and never modifies Remnawave's `ip remnanode` table.

This avoids Docker bridge addresses such as `172.17.0.2`, which may conflict with Remnawave
`egressFilter` rules blocking RFC1918 ranges (including `172.16.0.0/12`). A host-network Remnanode can
continue connecting to loopback without adding an egress-filter exception.

## Xray

Use the installer-reported port (1080 by default):

```json
{
  "tag": "psiphon-out",
  "protocol": "socks",
  "settings": { "address": "127.0.0.1", "port": 1080 }
}
```

Psiphon SOCKS is **TCP-only**. Do not route UDP through `psiphon-out`.

## Operations

```bash
vps-psiphon status
vps-psiphon logs
vps-psiphon restart
vps-psiphon uninstall
```

`status` checks the actual nftables table and both port rules. A missing or incomplete guard is shown
as `MISSING — SOCKS MAY BE PUBLIC`. Uninstall disables both units and removes the guard table. Useful
manual checks are:

```bash
docker inspect vps-psiphon --format '{{.HostConfig.NetworkMode}}'
nft list table inet psiphon_guard
curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

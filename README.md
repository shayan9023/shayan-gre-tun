
# Shayan GRE Tunnel Manager

A Bash menu manager for GRE tunnels with TCP, UDP, or combined port forwarding.

## Install

Run the installer as root:

```bash
curl -fsSL https://raw.githubusercontent.com/shayan9023/shayan-gre-tun/main/install.sh | sudo bash
```

The installer checks the downloaded manager's syntax before replacing `/usr/local/bin/shayan`, and creates `/usr/bin/shayan` when that command path is free so the command works in typical root shells. Tunnel profiles are stored under `/etc/vatan-gre-manager/profiles` and remain in place when the manager is upgraded.

Run the manager with:

```bash
sudo shayan
```

## Manage tunnels

Choose **Manage existing tunnels** to list saved tunnel profiles and select one. The manager keeps each profile's settings on disk, so selecting, stopping, restarting, or upgrading the manager does not discard them.

Under **Edit settings**, choose **Custom port** and enter one or more comma-separated ports, for example `443,8443,10000`. Ports must be between 1 and 65535 and cannot be repeated. The manager applies every listed port for TCP, UDP, or both, as selected in the profile. Existing profiles that contain a single `SERVICE_PORT` are migrated to the new multi-port setting when loaded.

The **All ports except 22** option remains available.

## Requirements

The manager requires root, Bash, `ip`, `iptables`, `iptables-save`, `sysctl`, `grep`, and `cksum`. The installer requires `curl`.

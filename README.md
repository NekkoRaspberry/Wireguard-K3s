# Wireguard-K3s

One WireGuard VPN server on K3s for secure access to the home network from anywhere. Each device (peer) gets its own key, and uses Pi-hole for DNS, so ads are blocked away from home too.

## Overview

| Item | Value |
|---|---|
| Namespace | `vpn` |
| Image | `lscr.io/linuxserver/wireguard:1.0.20260223-r0-ls129` |
| VPN port | `<PI_IP>:51820` (UDP) |
| VPN network | `10.13.13.0/24` (server `10.13.13.1`) |
| Through the VPN | Home network `<HOME_NETWORK>`, Pi-hole `10.43.0.53` (all other traffic goes direct) |
| Device DNS | Pi-hole `10.43.0.53` (see Pihole-K3s) |
| Storage | 100 Mi, `local-path` (server key and peer configs) |
| Memory limit | 128 Mi |
| Peer list | ConfigMap `wireguard-peers` (managed by the scripts) |
| Home network range | ConfigMap `home-network` (created at install, not in git) |
| Permissions | `NET_ADMIN` only (not privileged) |

> `<PI_IP>` is the Pi's address on your home network (`hostname -I`, first value). `<HOME_NETWORK>` is its range (e.g. `x.x.x.0/24`), `<ROUTER_IP>` the router's address.

## Files

| File | Purpose |
|---|---|
| `wireguard.yaml` | Namespace, service, storage and WireGuard |
| `new-peer.sh` | Creates a key and config for one device |
| `remove-peer.sh` | Removes one device's key |
| `tests/` | Tests, run on the Pi |
| `.github/workflows/tests.yml` | Checks scripts and manifest on push to `main` and `dev` |

## Install

Install Pihole-K3s first (devices use it for DNS).

```bash
export KUBECONFIG=~/.kube/config
kubectl create namespace vpn
# The home network range, kept on the Pi only (sent through the VPN)
kubectl create configmap home-network -n vpn \
  --from-literal=range="$(ip -o -4 route show dev eth0 scope link | awk '{print $1}')"
# First device. WireGuard needs at least one peer (with none it is not a server).
kubectl create configmap wireguard-peers -n vpn --from-literal=peers=phone
kubectl apply -f wireguard.yaml
kubectl rollout status deployment/wireguard -n vpn --timeout=120s
./tests/run-all.sh
```

### Reach it from outside

1. Give the Pi a fixed address in the router (DHCP reservation for `<PI_IP>`).
2. In the router, forward **UDP 51820** to `<PI_IP>`. This is the only port opened to the internet. Only devices with a valid key get an answer; to everyone else the port looks closed.
3. The public address is detected at start (`SERVERURL: auto`). If the home IP changes often, use a dynamic DNS name and set it as `SERVERURL` in `wireguard.yaml`.

## Add a device

This image has no web UI: the scripts keep the peer list, keys and restart in step.

```bash
./new-peer.sh <peer-name>
# example: ./new-peer.sh laptop
kubectl exec -n vpn deploy/wireguard -- /app/show-peer laptop   # QR code for the WireGuard app
```

The QR code contains the device's private key: show it only on your own screen. For a laptop, copy the config file instead:
```bash
kubectl exec -n vpn deploy/wireguard -- cat /config/peer_laptop/peer_laptop.conf > laptop.conf
```
WireGuard restarts for a few seconds; connected devices reconnect on their own.

Test from **outside** the home network (e.g. phone on mobile data): open a home address, e.g. the router at `http://<ROUTER_IP>`.

## Remove a device

```bash
./remove-peer.sh <peer-name>
```

Its key is deleted, so a lost or stolen device can no longer connect. The last peer cannot be removed.

## Useful commands

```bash
kubectl get pods,pvc,svc -n vpn                                  # status
kubectl logs -n vpn deploy/wireguard --tail=50                   # logs
kubectl exec -n vpn deploy/wireguard -- wg show                  # connected devices, last handshake
kubectl get configmap -n vpn wireguard-peers -o jsonpath='{.data.peers}'; echo   # peer names
```

## Tests

Run on the Pi:
```bash
./tests/run-all.sh
```

| Test | Checks |
|---|---|
| `01-running.sh` | Pod, storage, port, interface, every peer loaded, version, IP forwarding, Pi-hole DNS, no keys in logs, memory |
| `02-peers.sh` | Add/remove peers, a real tunnel per peer, DNS through the tunnel, unknown and removed keys rejected |
| `03-deploying.sh` | Manifest valid, no drift, server key and peers survive a restart |
| `99-leftovers.sh` | Nothing left behind by the tests |

The helper pod (a fake device) uses the temporary namespace `vpntest`, deleted at the end. Adding and removing test peers restarts WireGuard a few times (a few seconds each).

On push, `.github/workflows/tests.yml` checks script syntax (shellcheck) and the manifest (kubeconform) on `ubuntu-latest` (it also works on `nekko-runners`). It has no access to the cluster.

## Notes

- Never commit peer configs (`*.conf`): they contain private keys.
- To send **all** traffic through home (e.g. on public Wi-Fi), set `ALLOWEDIPS` to `0.0.0.0/0` in `wireguard.yaml`, apply, then re-import every device's config.
- Changing `SERVERURL`, `PEERDNS` or `ALLOWEDIPS` regenerates all peer configs (keys stay the same); re-import them on the devices.

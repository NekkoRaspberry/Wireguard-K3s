#!/usr/bin/env bash
# Is the file valid, does the cluster match it, and do keys survive a restart?
# Adding a peer restarts WireGuard, so this must always work.
source "$(dirname "$0")/lib.sh"
echo "== 03 Deploying"

check "manifest is valid (server dry-run)" kubectl apply --dry-run=server -f "$ROOT/wireguard.yaml"
# kubectl diff returns 0 when the cluster matches the file exactly
check "cluster matches the file (no drift)" kubectl diff -f "$ROOT/wireguard.yaml"

# Create a peer, restart WireGuard, check the server key and the peer still work
P=vpntestp
cleanup() { tunnel_down; has_peer "$P" && "$ROOT/remove-peer.sh" "$P" >/dev/null 2>&1; }
trap 'cleanup; client_stop' EXIT
client_start
cleanup

"$ROOT/new-peer.sh" "$P" >/dev/null
CONF_P="$(peer_conf "$P")"
KEY_BEFORE="$(in_server cat /config/server/publickey-server)"

echo "  ...restarting WireGuard"
kubectl rollout restart deployment/wireguard -n "$NS" >/dev/null
check "WireGuard comes back Ready after restart" \
  kubectl rollout status deployment/wireguard -n "$NS" --timeout=120s
check "server key survives a restart" test "$(in_server cat /config/server/publickey-server)" = "$KEY_BEFORE"
check "peer config survives a restart" test "$(peer_conf "$P")" = "$CONF_P"
tunnel_up "$CONF_P" >/dev/null 2>&1
check "peer still connects after restart" tunnel_ping

finish

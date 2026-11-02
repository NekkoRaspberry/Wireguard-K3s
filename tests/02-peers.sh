#!/usr/bin/env bash
# Do new-peer.sh and remove-peer.sh work, and can only valid keys connect?
# Creates temporary peers and removes them at the end.
# NOTE: adding/removing a peer restarts WireGuard (a few seconds each).
source "$(dirname "$0")/lib.sh"
echo "== 02 Peers (new-peer.sh, remove-peer.sh)"

A=vpntesta
B=vpntestb

cleanup() {
  tunnel_down
  for P in "$A" "$B"; do
    has_peer "$P" && "$ROOT/remove-peer.sh" "$P" >/dev/null 2>&1
  done
}
trap 'cleanup; client_stop' EXIT
client_start
cleanup   # start from a clean state
BEFORE="$(server_count)"

check_fails "rejects missing arguments" "$ROOT/new-peer.sh"
check_fails "rejects invalid peer name" "$ROOT/new-peer.sh" Bad-Name
check "creates peer A"                  "$ROOT/new-peer.sh" "$A"
check "creates peer B"                  "$ROOT/new-peer.sh" "$B"
check_fails "refuses to create the same peer twice" "$ROOT/new-peer.sh" "$A"
check "server knows both new peers"     test "$(server_count)" = $((BEFORE + 2))

CONF_A="$(peer_conf "$A")"
CONF_B="$(peer_conf "$B")"
for KEY in PrivateKey PresharedKey PublicKey Endpoint Address; do
  check "A's config contains '$KEY'" contains "$CONF_A" "$KEY = "
done
check_fails "A and B have different keys" \
  test "$(awk '/^PrivateKey/ {print $3}' <<< "$CONF_A")" = "$(awk '/^PrivateKey/ {print $3}' <<< "$CONF_B")"

check "A's tunnel comes up"         tunnel_up "$CONF_A"
check "A reaches the server through the tunnel" tunnel_ping
if pihole_installed; then check "DNS through the tunnel reaches Pi-hole" tunnel_dns
else warn "Pi-hole not installed, DNS through the tunnel not checked"; fi

tunnel_up "$CONF_A" "$(kubectl exec -n "$TEST_NS" "$CLIENT" -- wg genkey)" >/dev/null 2>&1
check_fails "an unknown key cannot connect"    tunnel_ping

tunnel_up "$CONF_B" >/dev/null 2>&1
check "B reaches the server through the tunnel" tunnel_ping

check "removes peer B"                         "$ROOT/remove-peer.sh" "$B"
check_fails "removed peer's files are deleted" in_server test -e "/config/peer_$B"
tunnel_up "$CONF_B" >/dev/null 2>&1
check_fails "removed peer can no longer connect" tunnel_ping
tunnel_up "$CONF_A" >/dev/null 2>&1
check "other peers keep working"               tunnel_ping
check_fails "removing an unknown peer fails"   "$ROOT/remove-peer.sh" "$B"
check_fails "remove rejects invalid peer name" "$ROOT/remove-peer.sh" Bad-Name

finish

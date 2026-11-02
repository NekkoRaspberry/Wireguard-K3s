# shellcheck shell=bash
# Shared helpers for the tests (loaded by each test file, not run directly)
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=vpn
TEST_NS=vpntest          # temporary namespace for the helper pod (deleted by run-all.sh)
CLIENT=vpntest-client    # helper pod with WireGuard tools, acts like a device
SERVER_IP=10.13.13.1     # server address inside the VPN
PIHOLE_IP=10.43.0.53     # Pi-hole, the DNS server given to devices
FAILS=0

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS + 1)); }
warn() { echo "  WARN  $1"; }

# check "<description>" <command...>  -> PASS if the command succeeds
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

# check_fails "<description>" <command...>  -> PASS if the command FAILS
check_fails() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi
}

# contains "<text>" "<part>"  -> succeeds if text contains part
contains() { grep -qF -- "$2" <<< "$1"; }

# Name of the running WireGuard pod (it changes after every restart)
wireguard_pod() { kubectl get pod -n "$NS" -l app=wireguard -o jsonpath='{.items[0].metadata.name}'; }

# Run a command in the WireGuard server
in_server() { kubectl exec -n "$NS" deploy/wireguard -- "$@"; }

# Is this peer in the list? (regex allowed, e.g. "vpntest[a-z0-9]*")
has_peer() {
  kubectl get configmap -n "$NS" wireguard-peers -o jsonpath='{.data.peers}' | tr ',' '\n' | grep -qx "$1"
}

# Number of peers in the list, and number the running server knows
list_count()   { kubectl get configmap -n "$NS" wireguard-peers -o jsonpath='{.data.peers}' | tr ',' '\n' | grep -c .; }
server_count() { in_server wg show wg0 peers | grep -c .; }

# A peer's config file (contains its private key: keep it in a variable, never print it)
peer_conf() { in_server cat "/config/peer_$1/peer_$1.conf"; }

# Helper pod with the same image as the server, allowed to create a VPN interface
client_start() {
  local image
  image="$(kubectl get deploy -n "$NS" wireguard -o jsonpath='{.spec.template.spec.containers[0].image}')"
  kubectl create namespace "$TEST_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl run "$CLIENT" -n "$TEST_NS" --restart=Never --image="$image" --overrides='{
    "spec": {"containers": [{
      "name": "'"$CLIENT"'", "image": "'"$image"'", "command": ["sleep", "600"],
      "securityContext": {"capabilities": {"add": ["NET_ADMIN"]}}
    }]}}' >/dev/null
  kubectl wait -n "$TEST_NS" --for=condition=Ready "pod/$CLIENT" --timeout=90s >/dev/null
}
client_stop() { kubectl delete pod -n "$TEST_NS" "$CLIENT" --ignore-not-found --grace-period=1 >/dev/null 2>&1; }

# Connect the helper pod to the VPN with a peer config, like a phone would.
# Usage: tunnel_up "<peer config>" [other private key]
# Uses the service's cluster address as endpoint (same server, reachable from a pod),
# and sends only the VPN server and Pi-hole through the tunnel.
tunnel_up() {
  local conf="$1" endpoint priv psk pub addr
  endpoint="$(kubectl get svc -n "$NS" wireguard -o jsonpath='{.spec.clusterIP}')"
  priv="${2:-$(awk '/^PrivateKey/ {print $3}' <<< "$conf")}"
  psk="$(awk '/^PresharedKey/ {print $3}' <<< "$conf")"
  pub="$(awk '/^PublicKey/ {print $3}' <<< "$conf")"
  addr="$(awk '/^Address/ {print $3}' <<< "$conf")"
  # Keys go in through stdin, so they never appear in a command line
  printf '%s\n%s\n' "$priv" "$psk" | kubectl exec -i -n "$TEST_NS" "$CLIENT" -- sh -c "
    set -e
    ip link del wg0 2>/dev/null || true
    umask 077; read -r k; read -r p; echo \"\$k\" > /tmp/key; echo \"\$p\" > /tmp/psk
    ip link add wg0 type wireguard
    wg set wg0 private-key /tmp/key peer '$pub' preshared-key /tmp/psk \
      endpoint '$endpoint:51820' allowed-ips '$SERVER_IP/32,$PIHOLE_IP/32'
    rm -f /tmp/key /tmp/psk
    ip addr add '$addr/32' dev wg0
    ip link set wg0 up
    ip route add '$SERVER_IP/32' dev wg0
    ip route add '$PIHOLE_IP/32' dev wg0"
}
tunnel_down() { kubectl exec -n "$TEST_NS" "$CLIENT" -- ip link del wg0 >/dev/null 2>&1 || true; }

# Can the helper pod reach the server through the tunnel?
tunnel_ping() { kubectl exec -n "$TEST_NS" "$CLIENT" -- ping -c 3 -W 3 "$SERVER_IP"; }

# Does DNS through the tunnel reach Pi-hole?
tunnel_dns() { contains "$(kubectl exec -n "$TEST_NS" "$CLIENT" -- nslookup example.com "$PIHOLE_IP" 2>&1)" "Name:"; }

# Is Pi-hole installed? (the DNS check is skipped without it)
pihole_installed() { kubectl get svc -n dns pihole-dns >/dev/null 2>&1; }

# Print the result and exit with 0 (all good) or 1 (something failed)
finish() {
  if [[ "$FAILS" -eq 0 ]]; then echo "  -> all passed"; exit 0
  else echo "  -> $FAILS failed"; exit 1; fi
}

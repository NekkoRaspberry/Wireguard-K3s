#!/usr/bin/env bash
# Is WireGuard running, reachable and keeping keys secret? (changes nothing)
source "$(dirname "$0")/lib.sh"
echo "== 01 Running"

POD="$(wireguard_pod)"

check "WireGuard pod is Ready" \
  kubectl wait -n "$NS" --for=condition=Ready "pod/$POD" --timeout=10s
check "storage (PVC) is Bound" \
  test "$(kubectl get pvc -n "$NS" wireguard-config -o jsonpath='{.status.phase}')" = Bound
check "VPN port is on the home network (LoadBalancer)" \
  test -n "$(kubectl get svc -n "$NS" wireguard -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
check "VPN port is 51820/UDP" \
  test "$(kubectl get svc -n "$NS" wireguard -o jsonpath='{.spec.ports[0].port}/{.spec.ports[0].protocol}')" = 51820/UDP
check "peer list exists" kubectl get configmap -n "$NS" wireguard-peers

check "VPN interface wg0 listens on 51820" test "$(in_server wg show wg0 listen-port)" = 51820
check "server knows every peer in the list" test "$(server_count)" = "$(list_count)"
check "WireGuard tools version is v1.0.20260223" contains "$(in_server wg --version)" v1.0.20260223
check "IP forwarding is on (devices can reach the home network)" \
  test "$(in_server cat /proc/sys/net/ipv4/ip_forward)" = 1

# Peer configs give devices Pi-hole as DNS
FIRST="$(kubectl get configmap -n "$NS" wireguard-peers -o jsonpath='{.data.peers}' | cut -d, -f1)"
check "devices use Pi-hole for DNS ($PIHOLE_IP)" contains "$(peer_conf "$FIRST")" "DNS = $PIHOLE_IP"

# Keys and QR codes must never be in the logs
LOGS="$(kubectl logs -n "$NS" "$POD" 2>&1)"
check_fails "no private keys in the logs" contains "$LOGS" PrivateKey
check_fails "no QR codes in the logs"     contains "$LOGS" "QR code (conf file"

# Memory: below 80% of the 128Mi limit
MEM="$(kubectl top pod -n "$NS" "$POD" --no-headers 2>/dev/null | awk '{print $3}' | tr -d 'Mi')"
if [[ -z "$MEM" ]]; then warn "memory usage unknown (metrics not ready yet)"
elif [[ "$MEM" -lt 102 ]]; then pass "memory usage ${MEM}Mi (< 80% of limit)"
else fail "memory usage ${MEM}Mi (>= 80% of 128Mi limit)"; fi

finish

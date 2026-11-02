#!/usr/bin/env bash
# Create a VPN peer (one device, e.g. a phone) with its own key and address.
# Its config and QR code are saved on the server, never printed by this script.
# Usage: ./new-peer.sh <peer-name>
set -euo pipefail
# Use ~/.kube/config on the Pi
if [[ -z "${KUBECONFIG:-}" && -f "$HOME/.kube/config" ]]; then export KUBECONFIG="$HOME/.kube/config"; fi

PEER="${1:-}"
if [[ -z "$PEER" ]]; then
  echo "Usage: $0 <peer-name>"
  exit 1
fi
# Lowercase letters and digits only (same rule as the other K3s projects)
if [[ ! "$PEER" =~ ^[a-z][a-z0-9]*$ ]]; then
  echo "Peer name must be lowercase letters and digits, starting with a letter."
  exit 1
fi

# Current peers, comma separated
PEERS="$(kubectl get configmap -n vpn wireguard-peers -o jsonpath='{.data.peers}')"

# Stop before changing anything if the peer already exists
if tr ',' '\n' <<< "$PEERS" | grep -qx "$PEER"; then
  echo "Peer '$PEER' already exists."
  exit 1
fi

# 1. Add the peer to the list
kubectl patch configmap -n vpn wireguard-peers --type merge \
  -p "{\"data\":{\"peers\":\"${PEERS:+$PEERS,}$PEER\"}}" >/dev/null

# 2. Restart WireGuard: it creates the key and config for new peers (a few seconds)
kubectl rollout restart deployment/wireguard -n vpn >/dev/null
kubectl rollout status deployment/wireguard -n vpn --timeout=120s >/dev/null

# Check the config really was created
if ! kubectl exec -n vpn deploy/wireguard -- test -f "/config/peer_$PEER/peer_$PEER.conf"; then
  echo "WireGuard did not create a config for '$PEER'. Check: kubectl logs -n vpn deploy/wireguard"
  exit 1
fi

echo "Done: peer '$PEER'. Show its QR code (scan it with the WireGuard app):"
echo "  kubectl exec -n vpn deploy/wireguard -- /app/show-peer $PEER"

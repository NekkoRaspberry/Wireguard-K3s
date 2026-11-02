#!/usr/bin/env bash
# Remove one VPN peer: its key is deleted and the device can no longer connect.
# Usage: ./remove-peer.sh <peer-name>
set -euo pipefail
# Use ~/.kube/config on the Pi
if [[ -z "${KUBECONFIG:-}" && -f "$HOME/.kube/config" ]]; then export KUBECONFIG="$HOME/.kube/config"; fi

PEER="${1:-}"
if [[ -z "$PEER" ]]; then
  echo "Usage: $0 <peer-name>"
  exit 1
fi
# Same rule as new-peer.sh
if [[ ! "$PEER" =~ ^[a-z][a-z0-9]*$ ]]; then
  echo "Peer name must be lowercase letters and digits, starting with a letter."
  exit 1
fi

PEERS="$(kubectl get configmap -n vpn wireguard-peers -o jsonpath='{.data.peers}')"
if ! tr ',' '\n' <<< "$PEERS" | grep -qx "$PEER"; then
  echo "Peer '$PEER' does not exist."
  exit 1
fi

# With an empty list WireGuard stops being a server, so keep at least one peer
REMAINING="$(tr ',' '\n' <<< "$PEERS" | grep -vx "$PEER" | paste -sd, - || true)"
if [[ -z "$REMAINING" ]]; then
  echo "Cannot remove the last peer: WireGuard needs at least one."
  exit 1
fi

# 1. Remove it from the list, 2. delete its key, 3. restart to load the change
kubectl patch configmap -n vpn wireguard-peers --type merge \
  -p "{\"data\":{\"peers\":\"$REMAINING\"}}" >/dev/null
kubectl exec -n vpn deploy/wireguard -- rm -rf "/config/peer_$PEER"
kubectl rollout restart deployment/wireguard -n vpn >/dev/null
kubectl rollout status deployment/wireguard -n vpn --timeout=120s >/dev/null

echo "Done: peer '$PEER' removed, it can no longer connect."

#!/usr/bin/env bash
# Did the tests clean up after themselves? (run last)
source "$(dirname "$0")/lib.sh"
echo "== 99 Leftovers"

check_fails "no test peers in the list"  has_peer "vpntest[a-z0-9]*"
check_fails "no test peer files left"    in_server sh -c 'ls -d /config/peer_vpntest*'
check "server knows only the listed peers" test "$(server_count)" = "$(list_count)"

finish

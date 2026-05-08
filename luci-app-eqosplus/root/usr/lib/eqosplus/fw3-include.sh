#!/bin/sh
# fw3 reload hook for eqosplus connection-limit (iptables backend).
#
# Purpose: When fw3 reloads, it rebuilds iptables tables from its own ruleset,
# which can drop our custom chain/jump and any rules inside it. This script
# rebuilds them without restarting the tc rate-limit side.
#
# Registered by uci-defaults/luci-eqosplus when backend=iptables.
# A no-op when backend=nft (fw4 doesn't touch our independent inet table).

[ "$(uci -q get eqosplus.@eqosplus[0].backend 2>/dev/null)" = "iptables" ] || exit 0
[ "$(uci -q get eqosplus.@eqosplus[0].service_enable 2>/dev/null)" = "1" ] || exit 0
[ -s /var/eqosplus.networks ] || exit 0

# Hand off to the main script — `conn_reload` rebuilds the chain skeleton,
# repopulates per-network bypass sets, and re-applies all currently-active
# connlimit rules. tc rules are untouched.
( eqosplus conn_reload ) >/dev/null 2>&1 &
exit 0

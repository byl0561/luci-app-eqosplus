#!/bin/sh
# eqosplus core tc operations - shared by main script and tests
# All functions take explicit parameters, no UCI dependency.
#
# Callers set EQOS_TC and EQOS_IP before sourcing:
#   EQOS_TC=dbg_tc  (main script, with logging)
#   EQOS_TC=tc       (tests, plain tc)

: ${EQOS_TC:=tc}
: ${EQOS_IP:=ip}
# Quiet variants for cleanup/teardown: no error logging (failures are expected)
: ${EQOS_TC_QUIET:=tc}
: ${EQOS_IP_QUIET:=ip}

# Check if a string is a valid MAC address (supports both : and - separators)
# Usage: is_macaddr "AA:BB:CC:DD:EE:FF"
# Pure case matching — zero forks (no echo|tr needed for detection)
is_macaddr() {
	case "$1" in
		[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f])
			return 0 ;;
		[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f])
			return 0 ;;
		*) return 1 ;;
	esac
}

# Calculate HTB quantum: rate_kbit*125 bytes (=rate_kbit*1000/8), clamped to [1500, 60000].
# Early-exit for rates >=480 kbit avoids large intermediate values that could
# overflow 32-bit arithmetic on some BusyBox ash builds.
# Result returned in $_quantum (no subshell fork).
_htb_quantum() {
	if [ "$1" -ge 480 ]; then
		_quantum=60000
	else
		_quantum=$(($1 * 125))
		[ "$_quantum" -lt 1500 ] && _quantum=1500
	fi
}

# Initialize tc infrastructure on a device (HTB, IFB, ingress)
# Usage: eqos_init_dev <dev>
eqos_init_dev() {
	local dev=$1
	[ -n "$dev" ] || return 1

	# Check IFB name length (Linux IFNAMSIZ=16, including null terminator)
	local ifb_name="${dev}_ifb"
	if [ ${#ifb_name} -gt 15 ]; then
		echo "eqos_init_dev: IFB name '${ifb_name}' exceeds 15 chars (got ${#ifb_name}), cannot create interface" >&2
		return 1
	fi

	$EQOS_IP_QUIET link del dev "${dev}_ifb" 2>/dev/null  # clean up any stale IFB from previous run
	$EQOS_IP link add dev "${dev}_ifb" type ifb || { eqos_teardown_dev "$dev"; return 1; }
	$EQOS_IP link set dev "${dev}_ifb" up                         || { eqos_teardown_dev "$dev"; return 1; }
	$EQOS_TC qdisc add dev "${dev}" root handle 1:0 htb default 1 || { eqos_teardown_dev "$dev"; return 1; }
	$EQOS_TC class add dev "${dev}" parent 1:0 classid 1:1 htb rate 10gbit prio 0 quantum 1500 || { eqos_teardown_dev "$dev"; return 1; }
	$EQOS_TC qdisc add dev "${dev}" parent 1:1 fq_codel || { eqos_teardown_dev "$dev"; return 1; }

	$EQOS_TC qdisc add dev "${dev}_ifb" root handle 1:0 htb default 1 || { eqos_teardown_dev "$dev"; return 1; }
	$EQOS_TC class add dev "${dev}_ifb" parent 1:0 classid 1:1 htb rate 10gbit prio 0 quantum 1500 || { eqos_teardown_dev "$dev"; return 1; }
	$EQOS_TC qdisc add dev "${dev}_ifb" parent 1:1 fq_codel || { eqos_teardown_dev "$dev"; return 1; }

	$EQOS_TC qdisc add dev "${dev}" ingress || { eqos_teardown_dev "$dev"; return 1; }
}

# Add a bypass rule for a subnet (traffic from/to this subnet is not rate-limited)
# Usage: eqos_add_bypass <dev> <subnet> <protocol: ip|ipv6> <prio>
eqos_add_bypass() {
	local dev=$1 subnet=$2 proto=$3 prio=$4
	[ -n "$dev" ] && [ -n "$subnet" ] && [ -n "$proto" ] && [ -n "$prio" ] || return 1
	case "$proto" in ip|ipv6) ;; *) return 1 ;; esac
	$EQOS_TC filter add dev "${dev}" parent 1:0 prio "$prio" protocol "$proto" flower src_ip "$subnet" classid 1:1 || return 1
	$EQOS_TC filter add dev "${dev}_ifb" parent 1:0 prio "$prio" protocol "$proto" flower dst_ip "$subnet" classid 1:1 || {
		$EQOS_TC filter del dev "${dev}" parent 1:0 prio "$prio" 2>/dev/null
		return 1
	}
}

# Tear down tc infrastructure on a device
# Usage: eqos_teardown_dev <dev>
eqos_teardown_dev() {
	local dev=$1
	[ -n "$dev" ] || return 1

	$EQOS_TC_QUIET filter del dev "${dev}" parent ffff: 2>/dev/null
	$EQOS_TC_QUIET qdisc del dev "${dev}" ingress 2>/dev/null

	$EQOS_TC_QUIET filter del dev "${dev}_ifb" parent 1:0 2>/dev/null
	$EQOS_TC_QUIET filter del dev "${dev}" parent 1:0 2>/dev/null

	$EQOS_TC_QUIET qdisc del dev "${dev}" root 2>/dev/null
	$EQOS_TC_QUIET qdisc del dev "${dev}_ifb" root 2>/dev/null

	$EQOS_IP_QUIET link del dev "${dev}_ifb" 2>/dev/null
}

# Add a MAC-based rate limit rule
# Usage: eqos_add_mac <dev> <id> <mac> <dl_kbit> <ul_kbit>
eqos_add_mac() {
	local dev=$1 id=$2 mac=$3 dl=$4 ul=$5
	[ -n "$dev" ] && [ -n "$id" ] && [ -n "$mac" ] || return 1
	case "$mac" in *-*) mac=${mac//-/:} ;; esac  # zero-fork, BusyBox ash 1.30+
	is_macaddr "$mac" || return 1
	dl=${dl:-0}; ul=${ul:-0}
	case "$dl" in ''|*[!0-9]*) dl=0 ;; esac
	case "$ul" in ''|*[!0-9]*) ul=0 ;; esac
	[ "$dl" -eq 0 ] && [ "$ul" -eq 0 ] && return 1

	# Clean up any existing rule for this id (makes add idempotent)
	eqos_del_id "$dev" "$id"

	if [ "$ul" -gt 0 ]; then
		_htb_quantum "$ul"
		# Create IFB class/qdisc/filter first, then add ingress redirect last
		$EQOS_TC class add dev "${dev}_ifb" parent 1:1 classid 1:"$id" htb rate "${ul}"kbit ceil "${ul}"kbit prio "$id" quantum "$_quantum" \
		&& $EQOS_TC qdisc add dev "${dev}_ifb" parent 1:"$id" handle "$id": fq_codel \
		&& $EQOS_TC filter add dev "${dev}_ifb" parent 1:0 prio "$id" protocol all flower src_mac "$mac" classid 1:"$id" \
		&& $EQOS_TC filter add dev "${dev}" parent ffff: prio "$id" protocol all flower src_mac "$mac" action mirred egress redirect dev "${dev}_ifb" \
		|| { eqos_del_id "$dev" "$id"; _eqos_verify_cleanup "$dev" "$id"; return 1; }
	fi
	if [ "$dl" -gt 0 ]; then
		_htb_quantum "$dl"
		$EQOS_TC class add dev "${dev}" parent 1:1 classid 1:"$id" htb rate "${dl}"kbit ceil "${dl}"kbit prio "$id" quantum "$_quantum" \
		&& $EQOS_TC qdisc add dev "${dev}" parent 1:"$id" handle "$id": fq_codel \
		&& $EQOS_TC filter add dev "${dev}" parent 1:0 prio "$id" protocol all flower dst_mac "$mac" classid 1:"$id" \
		|| { eqos_del_id "$dev" "$id"; _eqos_verify_cleanup "$dev" "$id"; return 1; }
	fi
}

# Add an IP-based rate limit rule
# Usage: eqos_add_ip <dev> <id> <ip_cidr> <dl_kbit> <ul_kbit>
eqos_add_ip() {
	local dev=$1 id=$2 ip_addr=$3 dl=$4 ul=$5
	[ -n "$dev" ] && [ -n "$id" ] && [ -n "$ip_addr" ] || return 1
	dl=${dl:-0}; ul=${ul:-0}
	case "$dl" in ''|*[!0-9]*) dl=0 ;; esac
	case "$ul" in ''|*[!0-9]*) ul=0 ;; esac
	[ "$dl" -eq 0 ] && [ "$ul" -eq 0 ] && return 1

	# Detect IPv6 (contains colon), but treat IPv4-mapped (::ffff:x.x.x.x) as IPv4
	local proto="ip" max_prefix=32
	case "$ip_addr" in
		::ffff:*) ip_addr="${ip_addr#::ffff:}" ;;
		::FFFF:*) ip_addr="${ip_addr#::FFFF:}" ;;
		*:*) proto="ipv6"; max_prefix=128 ;;
	esac

	# Extract CIDR prefix using shell parameter expansion (no fork)
	local prefix
	case "$ip_addr" in
		*/*) prefix="${ip_addr##*/}"; ip_addr="${ip_addr%%/*}" ;;
		*)   prefix="$max_prefix" ;;
	esac
	# Validate CIDR prefix range
	case "$prefix" in ''|*[!0-9]*) return 1 ;; esac
	[ "$prefix" -ge 1 ] && [ "$prefix" -le "$max_prefix" ] || return 1

	# Clean up any existing rule for this id (makes add idempotent)
	eqos_del_id "$dev" "$id"

	if [ "$ul" -gt 0 ]; then
		_htb_quantum "$ul"
		# Create IFB class/qdisc/filter first, then add ingress redirect last
		$EQOS_TC class add dev "${dev}_ifb" parent 1:1 classid 1:"$id" htb rate "${ul}"kbit ceil "${ul}"kbit prio "$id" quantum "$_quantum" \
		&& $EQOS_TC qdisc add dev "${dev}_ifb" parent 1:"$id" handle "$id": fq_codel \
		&& $EQOS_TC filter add dev "${dev}_ifb" parent 1:0 prio "$id" protocol "$proto" flower src_ip "$ip_addr/$prefix" classid 1:"$id" \
		&& $EQOS_TC filter add dev "${dev}" parent ffff: prio "$id" protocol "$proto" flower src_ip "$ip_addr/$prefix" action mirred egress redirect dev "${dev}_ifb" \
		|| { eqos_del_id "$dev" "$id"; _eqos_verify_cleanup "$dev" "$id"; return 1; }
	fi
	if [ "$dl" -gt 0 ]; then
		_htb_quantum "$dl"
		$EQOS_TC class add dev "${dev}" parent 1:1 classid 1:"$id" htb rate "${dl}"kbit ceil "${dl}"kbit prio "$id" quantum "$_quantum" \
		&& $EQOS_TC qdisc add dev "${dev}" parent 1:"$id" handle "$id": fq_codel \
		&& $EQOS_TC filter add dev "${dev}" parent 1:0 prio "$id" protocol "$proto" flower dst_ip "$ip_addr/$prefix" classid 1:"$id" \
		|| { eqos_del_id "$dev" "$id"; _eqos_verify_cleanup "$dev" "$id"; return 1; }
	fi
}

# True (0) if ANY tc artifact for <dev>/<id> still exists. Checks all
# three filter locations (not just classes): a residual filter at this
# prio is what shadows a different-id rule for the SAME ip — tc evaluates
# filters by ascending pref and stops at first match, so a stale lower
# pref steals traffic into the wrong/looser class.
_eqos_tc_residual() {
	local dev=$1 id=$2
	$EQOS_TC_QUIET filter show dev "${dev}" parent ffff:  2>/dev/null | grep -q "pref ${id} " && return 0
	$EQOS_TC_QUIET filter show dev "${dev}_ifb" parent 1:0 2>/dev/null | grep -q "pref ${id} " && return 0
	$EQOS_TC_QUIET filter show dev "${dev}" parent 1:0    2>/dev/null | grep -q "pref ${id} " && return 0
	$EQOS_TC_QUIET class show dev "${dev}" classid 1:"$id"     2>/dev/null | grep -q . && return 0
	$EQOS_TC_QUIET class show dev "${dev}_ifb" classid 1:"$id" 2>/dev/null | grep -q . && return 0
	return 1
}

_eqos_tc_del_once() {
	local dev=$1 id=$2
	$EQOS_TC_QUIET filter del dev "${dev}" parent ffff: prio "$id" 2>/dev/null
	$EQOS_TC_QUIET filter del dev "${dev}_ifb" parent 1:0 prio "$id" 2>/dev/null
	$EQOS_TC_QUIET filter del dev "${dev}" parent 1:0 prio "$id" 2>/dev/null
	$EQOS_TC_QUIET qdisc del dev "${dev}" parent 1:"$id" 2>/dev/null
	$EQOS_TC_QUIET qdisc del dev "${dev}_ifb" parent 1:"$id" 2>/dev/null
	$EQOS_TC_QUIET class del dev "${dev}" parent 1:1 classid 1:"$id" 2>/dev/null
	$EQOS_TC_QUIET class del dev "${dev}_ifb" parent 1:1 classid 1:"$id" 2>/dev/null
}

# Delete a rate limit rule (both directions) and VERIFY it is gone.
# Usage: eqos_del_id <dev> <id>
# Contract (relied on by del_id / add_ip / add_mac): return 0 = artifacts
# for <id> are CONFIRMED ABSENT (deleted now, or already absent);
# return 1 = still present after retries (netlink contention). tc del exit
# codes are deliberately NOT used to judge success — they are non-zero
# whenever there was nothing to delete, which is the normal case for the
# preemptive cleanup add_ip/add_mac do before adding.
eqos_del_id() {
	local dev=$1 id=$2 _try
	[ -n "$dev" ] && [ -n "$id" ] || return 1
	for _try in 1 2 3; do
		_eqos_tc_del_once "$dev" "$id"
		_eqos_tc_residual "$dev" "$id" || return 0
		[ "$_try" -lt 3 ] && sleep 0.1 2>/dev/null
	done
	logger -t eqosplus "WARN tc artifacts for id $id on $dev still present after del+retry" 2>/dev/null
	return 1
}

# Verify that tc resources for an id have been fully cleaned up after eqos_del_id.
# Logs a warning (via stderr) if orphaned classes remain in kernel memory.
# Usage: _eqos_verify_cleanup <dev> <id>
_eqos_verify_cleanup() {
	local dev=$1 id=$2
	[ -n "$dev" ] && [ -n "$id" ] || return
	local d
	for d in "$dev" "${dev}_ifb"; do
		$EQOS_TC_QUIET class show dev "$d" classid 1:"$id" 2>/dev/null | grep -q . \
			&& echo "eqos: WARN orphaned tc class 1:$id on $d after cleanup" >&2
	done
}

# =============================================================================
# Connection limit (conn_in / conn_out) — fw4/nft and fw3/iptables backends
# =============================================================================
# Backend selection: $EQOS_BACKEND is "nft", "iptables", or "none".
# Resolved once at install time (postinst writes UCI option, main script reads it).
# All eqos_*_conn_* functions are no-ops when backend is "none" or unsupported.
#
# Semantics:
#   - "Connection" = one conntrack 5-tuple entry (bidirectional flow, single count)
#   - Direction "out": original-tuple source = device (device-initiated)
#   - Direction "in":  original-tuple dest   = device (port-forwarded inbound,
#     e.g. PCDN servers). MAC source-side rules cannot match destinations
#     because L2 daddr is rewritten only AFTER the FORWARD hook by the neigh
#     subsystem — eqos_add_conn returns 1 for MAC+in.
#   - Same-zone bypass: traffic destined to a same-zone peer subnet is RETURNed
#     before counting (mirrors tc bypass behavior)
#   - tcp_only=1 (default): only TCP flows count; tcp_only=0: all protocols
#   - CIDR identifiers: count is *subnet-wide* (single shared budget for the
#     whole CIDR). Both backends are aligned to this — iptables uses
#     --connlimit-mask <prefix> from the CIDR; nft's `ct count` over a saddr
#     CIDR clause has the same shared-budget semantic.
#
# Identifier policy (enforced in upper layers, NOT in these primitives):
#   - MAC + conn_in/conn_out is NOT supported as a feature. The CBI form
#     greys-out conn inputs when MAC is selected (JS readOnly + value=0),
#     ip.validate rejects the form on save if it leaks through, and the
#     add_mac wrapper never calls eqos_add_conn for MAC (only sweeps any
#     leftover via eqos_del_conn). The primitives below will still accept
#     MAC+out in case some future caller needs it — the rejection is a
#     policy decision, not a kernel limitation.
#
# Comment scheme (used to identify rules for delete/sweep operations):
#   - Per-rule:    "eqos:rule:<network>[<idx>]"   exact match for delete;
#                                                 prefix "eqos:rule:<net>[" for
#                                                 per-network sweep
#   - Per-bypass:  "eqos:bypass:<network>:"       trailing ':' anchors so
#                                                 "lan:" doesn't match "lan2:"

# ---- nft backend -----------------------------------------------------------

# Initialize the inet eqosplus table and forward chain (idempotent).
# Logs to stderr on failure — caller's logger captures it. Without this,
# missing kmod-nft-core or syntax breakage would silently disable the
# entire conn-limit feature with no diagnostic trail.
eqos_init_conn_table_nft() {
	nft list table inet eqosplus >/dev/null 2>&1 && return 0
	nft -f - 2>/dev/null <<-NFTEOF
	table inet eqosplus {
		chain forward {
			type filter hook forward priority -10; policy accept;
		}
	}
	NFTEOF
	local rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "eqos_init_conn_table_nft: nft -f returned $rc (kernel module missing or nft incompatible?)" >&2
		return 1
	fi
	return 0
}

eqos_teardown_conn_table_nft() {
	nft delete table inet eqosplus 2>/dev/null
	return 0
}

# Per-network bypass init: create sets and add iifname-scoped bypass rules.
# Usage: eqos_init_conn_network_nft <network> <dev>
eqos_init_conn_network_nft() {
	local network=$1 dev=$2
	[ -n "$network" ] && [ -n "$dev" ] || return 1
	nft list set inet eqosplus "bypass4_${network}" >/dev/null 2>&1 || \
		nft add set inet eqosplus "bypass4_${network}" '{ type ipv4_addr; flags interval; }' 2>/dev/null
	nft list set inet eqosplus "bypass6_${network}" >/dev/null 2>&1 || \
		nft add set inet eqosplus "bypass6_${network}" '{ type ipv6_addr; flags interval; }' 2>/dev/null
	# Add bypass rules only if not already present (idempotent on restart).
	# Trailing ':' makes "eqos:bypass:lan:" a unique anchor (won't match "lan2:").
	if ! nft -a list chain inet eqosplus forward 2>/dev/null | grep -qF "\"eqos:bypass:${network}:\""; then
		nft add rule inet eqosplus forward iifname "$dev" ip daddr "@bypass4_${network}" return comment "\"eqos:bypass:${network}:\"" 2>/dev/null
		nft add rule inet eqosplus forward iifname "$dev" ip6 daddr "@bypass6_${network}" return comment "\"eqos:bypass:${network}:\"" 2>/dev/null
	fi
}

eqos_teardown_conn_network_nft() {
	local network=$1
	[ -n "$network" ] || return 1
	# Wipe per-rule entries for this network FIRST, then bypass + sets.
	# Without this sweep, stop_network leaves orphaned per-rule connlimits.
	_eqos_nft_purge_by_prefix "eqos:rule:${network}["
	_eqos_nft_delete_by_comment "eqos:bypass:${network}:"
	nft delete set inet eqosplus "bypass4_${network}" 2>/dev/null
	nft delete set inet eqosplus "bypass6_${network}" 2>/dev/null
	return 0
}

# Replace bypass set contents.
# Usage: eqos_update_bypass_set_nft <network> <v4-subnets-space-sep> <v6-subnets-space-sep>
eqos_update_bypass_set_nft() {
	local network=$1 v4_list=$2 v6_list=$3
	[ -n "$network" ] || return 1
	nft flush set inet eqosplus "bypass4_${network}" 2>/dev/null
	nft flush set inet eqosplus "bypass6_${network}" 2>/dev/null
	# Squeeze repeated spaces and strip leading/trailing whitespace before
	# comma-joining — defends against accumulator hiccups producing empty
	# elements (which nft rejects).
	if [ -n "$v4_list" ]; then
		local elems=$(echo "$v4_list" | tr -s ' ' ',' | sed -e 's/^,//' -e 's/,$//')
		[ -n "$elems" ] && nft add element inet eqosplus "bypass4_${network}" "{ $elems }" 2>/dev/null
	fi
	if [ -n "$v6_list" ]; then
		local elems=$(echo "$v6_list" | tr -s ' ' ',' | sed -e 's/^,//' -e 's/,$//')
		[ -n "$elems" ] && nft add element inet eqosplus "bypass6_${network}" "{ $elems }" 2>/dev/null
	fi
	return 0
}

# Add a per-rule connlimit.
# Usage: eqos_add_conn_nft <rule_id> <addr> <limit> <tcp_only> <dir:in|out>
#   <rule_id> is the UCI section identifier "<network>[<idx>]" (e.g. "lan[0]")
#             — used as the comment tag, NOT the cal_uuid numeric value.
eqos_add_conn_nft() {
	local rule_id=$1 addr=$2 limit=$3 tcp_only=$4 dir=$5
	[ -n "$rule_id" ] && [ -n "$addr" ] || return 1
	case "$limit" in ''|*[!0-9]*) return 1 ;; esac
	[ "$limit" -gt 0 ] || return 1
	case "$dir" in in|out) ;; *) dir=out ;; esac

	# Caller (add_mac/add_ip) clears existing rules for this id once before
	# adding directions; both in/out share the same comment so per-call
	# deletion would clobber the other direction.

	case "$addr" in *-*) addr=${addr//-/:} ;; esac

	local match
	if is_macaddr "$addr"; then
		# Source-MAC only — see header comment about FORWARD-time L2 daddr.
		[ "$dir" = "out" ] || return 1
		match="ether saddr $addr"
	else
		local sd
		[ "$dir" = "out" ] && sd="saddr" || sd="daddr"
		case "$addr" in
			::ffff:*) addr="${addr#::ffff:}"; match="ip $sd $addr" ;;
			::FFFF:*) addr="${addr#::FFFF:}"; match="ip $sd $addr" ;;
			*:*) match="ip6 $sd $addr" ;;
			*)   match="ip $sd $addr" ;;
		esac
	fi

	local proto_match=""
	[ "$tcp_only" = "1" ] && proto_match="meta l4proto tcp"

	# `counter` placed AFTER `ct count over` so it only increments on REJECT
	# hits (same semantics as iptables `-j REJECT` per-rule pkt counter).
	# shellcheck disable=SC2086
	nft add rule inet eqosplus forward $match $proto_match ct count over "$limit" counter reject comment "\"eqos:rule:${rule_id}\"" 2>/dev/null
}

# Usage: eqos_del_conn_nft <rule_id>
eqos_del_conn_nft() {
	local rule_id=$1
	[ -n "$rule_id" ] || return 1
	# Exact-match: closing '"' from nft's quoted comment anchors the end so
	# "lan[0]" doesn't match "lan[00]".
	_eqos_nft_delete_by_comment "eqos:rule:${rule_id}"
}

# Delete all per-rule conn entries for a network in one sweep.
# Used by stop_network to avoid orphaned rules when a network goes away.
# Usage: eqos_purge_conn_for_network_nft <network>
eqos_purge_conn_for_network_nft() {
	local network=$1
	[ -n "$network" ] || return 1
	_eqos_nft_purge_by_prefix "eqos:rule:${network}["
}

# Delete all rules whose comment EXACTLY equals $1 (anchored by nft's quote).
# nft has no iptables-legacy two-syscall RCU race, so an unreadable
# `nft list` almost always means the table/chain is absent (nothing to
# delete, no duplicate risk) -> treat as success. A POSITIVE residual
# after deleting handles IS a failure (surfaced so callers don't add a
# duplicate), symmetric with the iptables path.
_eqos_nft_delete_by_comment() {
	local comment=$1
	[ -n "$comment" ] || return 1
	local dump
	dump=$(nft -a list chain inet eqosplus forward 2>/dev/null) || return 0
	printf '%s\n' "$dump" | awk -v c="\"${comment}\"" '
		index($0, c) && match($0, /handle [0-9]+/) {
			print substr($0, RSTART + 7, RLENGTH - 7)
		}
	' | while read -r handle; do
		[ -n "$handle" ] && nft delete rule inet eqosplus forward handle "$handle" 2>/dev/null
	done
	dump=$(nft -a list chain inet eqosplus forward 2>/dev/null) || return 0
	if printf '%s\n' "$dump" | grep -qF -- "\"${comment}\""; then
		logger -t eqosplus "WARN residual '$comment' in nft eqos forward after delete" 2>/dev/null
		return 1
	fi
	return 0
}

# Delete all rules whose comment STARTS WITH $1 (un-anchored prefix match).
# Pattern must include a trailing delimiter (typically '[' or ':') for
# uniqueness — otherwise "lan" prefix would also match "lan2".
_eqos_nft_purge_by_prefix() {
	local prefix=$1
	[ -n "$prefix" ] || return 1
	local dump
	dump=$(nft -a list chain inet eqosplus forward 2>/dev/null) || return 0
	printf '%s\n' "$dump" | awk -v p="\"${prefix}" '
		index($0, p) && match($0, /handle [0-9]+/) {
			print substr($0, RSTART + 7, RLENGTH - 7)
		}
	' | while read -r handle; do
		[ -n "$handle" ] && nft delete rule inet eqosplus forward handle "$handle" 2>/dev/null
	done
	dump=$(nft -a list chain inet eqosplus forward 2>/dev/null) || return 0
	if printf '%s\n' "$dump" | grep -qF -- "\"${prefix}"; then
		logger -t eqosplus "WARN residual prefix '$prefix' in nft eqos forward after purge" 2>/dev/null
		return 1
	fi
	return 0
}

# ---- iptables backend ------------------------------------------------------

eqos_init_conn_table_ipt() {
	iptables  -w 5 -nL eqos_forward >/dev/null 2>&1 || iptables  -w 5 -N eqos_forward 2>/dev/null
	ip6tables -w 5 -nL eqos_forward >/dev/null 2>&1 || ip6tables -w 5 -N eqos_forward 2>/dev/null
	iptables  -w 5 -C FORWARD -j eqos_forward 2>/dev/null || iptables  -w 5 -I FORWARD 1 -j eqos_forward 2>/dev/null
	ip6tables -w 5 -C FORWARD -j eqos_forward 2>/dev/null || ip6tables -w 5 -I FORWARD 1 -j eqos_forward 2>/dev/null
}

# True (0) iff this family's iptables FILTER table is registered in the
# kernel — i.e. that protocol is actually enabled. IDENTICAL logic for v4
# and v6 (no family-name special-case); the only difference is which proc
# file, i.e. whether that protocol is turned on. Used to decide `critical`:
# table registered + dump unreadable = xtables-lock contention (the bug ->
# must surface); table NOT registered (proto/module off) = a legitimately
# empty ruleset -> tolerate. Lock contention does NOT unregister the table,
# so it still reads as active and the real bug is still surfaced.
#
# PRECONDITION: these are iptables-legacy x_tables proc interfaces.
# EQOS_BACKEND=iptables is chosen only when no nft binary exists (backend
# autodetect / uci-defaults prefer nft) -> the system is iptables-legacy,
# where these files exist. The bug this critical flag guards (iptables-save
# two-syscall EAGAIN race) is itself legacy-only (see _eqos_ipt_save_retry);
# an iptables-nft compat layer has neither the race nor these proc files
# and never reaches this path in a correctly-detected setup. A hand-forced
# backend=iptables on a pure nft-compat box (no nft binary) is out of scope.
_eqos_proto_active() {
	case "$1" in
		iptables)  grep -qx filter /proc/net/ip_tables_names  2>/dev/null ;;
		ip6tables) grep -qx filter /proc/net/ip6_tables_names 2>/dev/null ;;
		*) return 1 ;;
	esac
}

# Flush one family's eqos_forward and VERIFY it is actually empty, retrying
# on transient lock contention. Without this, a -F that lost the xtables
# lock left a dirty chain that init then appended onto -> duplicate REJECTs.
# $1 = iptables|ip6tables. critical via _eqos_proto_active (same v4/v6
# rule): protocol's filter table registered + unverifiable after retry =
# lock contention = fail; protocol off -> tolerate.
_eqos_ipt_flush_chain_verified() {
	local cmd=$1 save_cmd="${1}-save" dump _try critical
	_eqos_proto_active "$cmd" && critical=1 || critical=0
	for _try in 1 2 3; do
		$cmd -w 5 -F eqos_forward 2>/dev/null
		if dump=$(_eqos_ipt_save_retry "$save_cmd"); then
			printf '%s\n' "$dump" | grep -q '^-A eqos_forward ' || return 0
		else
			[ "$critical" = 1 ] || return 0
		fi
		[ "$_try" -lt 3 ] && sleep 0.1 2>/dev/null
	done
	logger -t eqosplus "WARN ${cmd} eqos_forward not empty after flush+retry" 2>/dev/null
	return 1
}

eqos_teardown_conn_table_ipt() {
	local rc=0
	iptables  -w 5 -D FORWARD -j eqos_forward 2>/dev/null
	ip6tables -w 5 -D FORWARD -j eqos_forward 2>/dev/null
	_eqos_ipt_flush_chain_verified iptables  || rc=1
	_eqos_ipt_flush_chain_verified ip6tables || rc=1
	iptables  -w 5 -X eqos_forward 2>/dev/null
	ip6tables -w 5 -X eqos_forward 2>/dev/null
	# Destroy any leftover ipsets
	local s
	for s in $(ipset list -name 2>/dev/null | grep '^eqos_bypass'); do
		ipset destroy "$s" 2>/dev/null
	done
	return $rc
}

# Second line of defense for the START path only. teardown's verified flush
# can still fail under sustained contention; this re-flushes any residual
# BEFORE init/start_network append onto the chain. NOT called from
# conn_reload (there the chain legitimately holds rules; flushing it every
# reload would needlessly reset counters — conn_reload's own purge-rebuild
# handles correctness). nft: teardown deletes the whole table atomically,
# so there is no dirty-chain-append hazard -> no-op.
eqos_force_clean_conn_table_ipt() {
	# Unconditional verified flush per family. _eqos_ipt_flush_chain_verified
	# uses a non-locking *-save to confirm emptiness, and a missing chain
	# trivially verifies clean (no -A lines) — so no lock-taking -nL gate.
	_eqos_ipt_flush_chain_verified iptables
	_eqos_ipt_flush_chain_verified ip6tables
	return 0
}

eqos_init_conn_network_ipt() {
	local network=$1 dev=$2
	[ -n "$network" ] && [ -n "$dev" ] || return 1
	ipset list "eqos_bypass4_${network}" >/dev/null 2>&1 || \
		ipset create "eqos_bypass4_${network}" hash:net family inet 2>/dev/null
	ipset list "eqos_bypass6_${network}" >/dev/null 2>&1 || \
		ipset create "eqos_bypass6_${network}" hash:net family inet6 2>/dev/null
	# Bypass comment uses trailing ':' so prefix match anchored on it.
	iptables -w 5 -C eqos_forward -i "$dev" -m set --match-set "eqos_bypass4_${network}" dst \
		-m comment --comment "eqos:bypass:${network}:" -j RETURN 2>/dev/null || \
	iptables -w 5 -I eqos_forward 1 -i "$dev" -m set --match-set "eqos_bypass4_${network}" dst \
		-m comment --comment "eqos:bypass:${network}:" -j RETURN 2>/dev/null
	ip6tables -w 5 -C eqos_forward -i "$dev" -m set --match-set "eqos_bypass6_${network}" dst \
		-m comment --comment "eqos:bypass:${network}:" -j RETURN 2>/dev/null || \
	ip6tables -w 5 -I eqos_forward 1 -i "$dev" -m set --match-set "eqos_bypass6_${network}" dst \
		-m comment --comment "eqos:bypass:${network}:" -j RETURN 2>/dev/null
}

eqos_teardown_conn_network_ipt() {
	local network=$1
	[ -n "$network" ] || return 1
	# Wipe per-rule entries for this network FIRST, then bypass + ipsets.
	_eqos_ipt_purge_by_prefix "eqos:rule:${network}["
	_eqos_ipt_delete_by_comment "eqos:bypass:${network}:"
	ipset destroy "eqos_bypass4_${network}" 2>/dev/null
	ipset destroy "eqos_bypass6_${network}" 2>/dev/null
	return 0
}

eqos_update_bypass_set_ipt() {
	local network=$1 v4_list=$2 v6_list=$3
	[ -n "$network" ] || return 1
	ipset flush "eqos_bypass4_${network}" 2>/dev/null
	ipset flush "eqos_bypass6_${network}" 2>/dev/null
	local s
	for s in $v4_list; do [ -n "$s" ] && ipset add "eqos_bypass4_${network}" "$s" 2>/dev/null; done
	for s in $v6_list; do [ -n "$s" ] && ipset add "eqos_bypass6_${network}" "$s" 2>/dev/null; done
	return 0
}

# Usage: eqos_add_conn_ipt <rule_id> <addr> <limit> <tcp_only> <dir:in|out>
#   <rule_id>: UCI section identifier "<network>[<idx>]" (used as comment tag).
#   <addr>:    MAC | IPv4 | IPv6 | CIDRv4 | CIDRv6.
# CIDR semantic: --connlimit-mask is set to the CIDR's prefix length so the
# count is a single shared budget for the whole subnet. Without /N the prefix
# defaults to /32 (IPv4) or /128 (IPv6), giving per-host counting for single
# addresses. This aligns with nft's `ct count` over a saddr/daddr CIDR clause.
eqos_add_conn_ipt() {
	local rule_id=$1 addr=$2 limit=$3 tcp_only=$4 dir=$5
	[ -n "$rule_id" ] && [ -n "$addr" ] || return 1
	case "$limit" in ''|*[!0-9]*) return 1 ;; esac
	[ "$limit" -gt 0 ] || return 1
	case "$dir" in in|out) ;; *) dir=out ;; esac

	case "$addr" in *-*) addr=${addr//-/:} ;; esac

	local proto_args=""
	[ "$tcp_only" = "1" ] && proto_args="-p tcp"

	# xt_connlimit defaults to --connlimit-saddr; pass --connlimit-daddr
	# explicitly for inbound so the count groups by destination IP.
	local addr_flag connlimit_side
	if [ "$dir" = "out" ]; then
		addr_flag="-s"; connlimit_side="--connlimit-saddr"
	else
		addr_flag="-d"; connlimit_side="--connlimit-daddr"
	fi

	if is_macaddr "$addr"; then
		# MAC matching only works for source — see nft path comment.
		[ "$dir" = "out" ] || return 1
		# Mask doesn't matter for a single MAC (one address).
		# shellcheck disable=SC2086
		iptables -w 5 -A eqos_forward -m mac --mac-source "$addr" $proto_args \
			-m connlimit --connlimit-above "$limit" --connlimit-mask 32 $connlimit_side \
			-m comment --comment "eqos:rule:${rule_id}" -j REJECT 2>/dev/null
		# shellcheck disable=SC2086
		ip6tables -w 5 -A eqos_forward -m mac --mac-source "$addr" $proto_args \
			-m connlimit --connlimit-above "$limit" --connlimit-mask 128 $connlimit_side \
			-m comment --comment "eqos:rule:${rule_id}" -j REJECT 2>/dev/null
		return 0
	fi

	case "$addr" in
		::ffff:*) addr="${addr#::ffff:}" ;;
		::FFFF:*) addr="${addr#::FFFF:}" ;;
	esac

	# Detect family and parse optional CIDR prefix to feed --connlimit-mask
	local is_v6=0 max_prefix=32 prefix
	case "$addr" in *:*) is_v6=1; max_prefix=128 ;; esac
	case "$addr" in
		*/*) prefix="${addr##*/}" ;;
		*)   prefix="$max_prefix" ;;
	esac
	# Defensive: if prefix isn't a valid integer in range, fall back to /max
	case "$prefix" in ''|*[!0-9]*) prefix="$max_prefix" ;; esac
	[ "$prefix" -ge 0 ] && [ "$prefix" -le "$max_prefix" ] || prefix="$max_prefix"

	if [ "$is_v6" = "1" ]; then
		# shellcheck disable=SC2086
		ip6tables -w 5 -A eqos_forward $addr_flag "$addr" $proto_args \
			-m connlimit --connlimit-above "$limit" --connlimit-mask "$prefix" $connlimit_side \
			-m comment --comment "eqos:rule:${rule_id}" -j REJECT 2>/dev/null
	else
		# shellcheck disable=SC2086
		iptables -w 5 -A eqos_forward $addr_flag "$addr" $proto_args \
			-m connlimit --connlimit-above "$limit" --connlimit-mask "$prefix" $connlimit_side \
			-m comment --comment "eqos:rule:${rule_id}" -j REJECT 2>/dev/null
	fi
}

# Usage: eqos_del_conn_ipt <rule_id>
eqos_del_conn_ipt() {
	local rule_id=$1
	[ -n "$rule_id" ] || return 1
	_eqos_ipt_delete_by_comment "eqos:rule:${rule_id}"
}

# Sweep all per-rule conn entries for a network — used by stop_network.
eqos_purge_conn_for_network_ipt() {
	local network=$1
	[ -n "$network" ] || return 1
	_eqos_ipt_purge_by_prefix "eqos:rule:${network}["
}

# Run iptables-save / ip6tables-save with retry on transient empty output.
# Why retry: iptables-save makes TWO getsockopt calls (SO_GET_INFO, then
# SO_GET_ENTRIES). If another process commits a rule change between them,
# the kernel RCU-swaps the table and the second call returns -EAGAIN due
# to size mismatch. libiptc-legacy does NOT retry — empty stdout silently
# breaks any caller piping through awk/grep, causing missed deletions and
# accumulating duplicate rules over time.
#
# CRITICAL: always scope the dump to `-t filter` (our eqos_forward chain
# lives only there; raw/mangle/nat are never needed). The EAGAIN race
# window scales with table size: on the very PCDN-suppression box this
# tool targets, the throttled 网心云 host punches ~770 UPnP mappings, so
# miniupnpd churns a HUGE nat table near-continuously. A full-table
# iptables-save then loses the SO_GET_INFO→SO_GET_ENTRIES race on almost
# every try, exhausting all 5 retries — which made eqos_del_conn /
# eqos_purge_all_conn report "failed" forever (del_id loops keeping the
# IDLIST entry → conn_reload resurrects the stale rule → duplicate REJECT;
# add_ip's clear-before-add fails → the rate-limit rule never commits).
# `-t filter` collapses the dump to the tiny, stable filter table so the
# race window is back to microseconds. (eqosplusctrl's sanity probe was
# already scoped this way; the mutation paths must match.)
# Note: -w is NOT a valid flag for iptables-save in iptables-legacy (not
# in its getopt string). iptables-save bypasses xtables.lock entirely.
# Tuning: 5 tries × 100ms backoff tolerates concurrent committers
# (openclash, miniupnpd) without masking real failures (missing kernel
# module, ENOENT).
_eqos_ipt_save_retry() {
	local cmd=$1 out rc _try
	for _try in 1 2 3 4 5; do
		out=$("$cmd" -t filter 2>/dev/null)
		rc=$?
		if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
			printf '%s\n' "$out"
			return 0
		fi
		[ "$_try" -lt 5 ] && sleep 0.1 2>/dev/null
	done
	# Exhausted: empty/failed output. Callers MUST check this exit status —
	# treating a missed dump as "nothing to delete" is what accumulated
	# duplicate REJECT rules (del silently no-ops, add then duplicates).
	logger -t eqosplus "WARN ${cmd} empty after 5 tries (xtables-lock/EAGAIN); delete treated as failed" 2>/dev/null
	return 1
}

# Delete rules whose comment EXACTLY equals $1.
# We use iptables-save (stable, machine-readable output) instead of iptables -L
# because -L's rendering of -m comment varies across builds: some show
# "/* x */", some bare, some omit it entirely without -v. iptables-save always
# emits "--comment "x"" (double-quoted) per rule, one rule per line starting
# with "-A <chain>", so each matching rule is deleted by its FULL SPEC
# (-A -> -D) — no line-number/handle dependency, no IFS dependency.
# Returns 0 only if, for every applicable family, the comment is verified
# ABSENT after the delete pass. Returns 1 if the ruleset was unreadable
# while that protocol is enabled (lock-contention bug — must surface) or a
# matching rule survived (a -D failed). Callers gate add-after-delete on
# this so a missed delete never turns into a duplicate.
#
# v4/v6 are treated IDENTICALLY (see _eqos_proto_active): `critical` is
# decided by whether THAT protocol's filter table is registered in the
# kernel, not by family name. Protocol enabled + unreadable dump = lock
# contention -> fail. Protocol off (no ip{,6}_tables) -> tolerated (its -A
# fails too, no dup can accrue). A POSITIVE residual always fails.
_eqos_ipt_delete_by_comment() {
	local comment=$1
	[ -n "$comment" ] || return 1
	local cmd save_cmd dump line rc=0 critical _try _residual
	for cmd in iptables ip6tables; do
		save_cmd="${cmd}-save"
		# critical iff this protocol's filter table is registered in the
		# kernel (see _eqos_proto_active) — IDENTICAL test for v4 and v6,
		# no family-name special-case. Registered + unreadable dump = lock
		# contention (the bug -> fail); protocol off -> tolerate (its -A
		# fails too, no rule can accrue). A POSITIVE residual always fails.
		_eqos_proto_active "$cmd" && critical=1 || critical=0
		# Up to 3 passes: re-dump fresh, delete every matching rule by
		# FULL SPEC (-A -> -D) — immune to nft handle / line-number drift
		# and independent of the caller's IFS (the IFS=, leak that fed
		# every rule number to one bogus `iptables -D` arg). Done when the
		# comment is gone from the eqos_forward chain.
		_residual=1
		for _try in 1 2 3; do
			if ! dump=$(_eqos_ipt_save_retry "$save_cmd"); then
				# v4 unreadable = contention bug, keep failing; v6
				# unreadable = tolerated (no v6 rule can exist anyway).
				[ "$critical" = 1 ] || { _residual=0; break; }
				[ "$_try" -lt 3 ] && sleep 0.1 2>/dev/null
				continue
			fi
			# printf|while subshell is fine: -D is a kernel side effect,
			# nothing returned. IFS= so a leaked IFS cannot merge lines.
			printf '%s\n' "$dump" | while IFS= read -r line; do
				case "$line" in "-A eqos_forward "*) ;; *) continue ;; esac
				case "$line" in *"--comment \"${comment}\""*) ;; *) continue ;; esac
				# spec is our own injected rule read back; comment is
				# eqos:rule:<net>[<idx>] (net [a-z0-9_], idx digits) — no
				# shell metacharacters, eval is controlled.
				eval "$cmd -w 2 -D eqos_forward ${line#-A eqos_forward }" 2>/dev/null
			done
			if dump=$(_eqos_ipt_save_retry "$save_cmd"); then
				if printf '%s\n' "$dump" | grep -F -- '-A eqos_forward ' | grep -qF -- "--comment \"${comment}\""; then
					_residual=1
				else
					_residual=0; break
				fi
			else
				# verify dump unreadable: same v4/v6 rule as above.
				[ "$critical" = 1 ] || { _residual=0; break; }
			fi
			[ "$_try" -lt 3 ] && sleep 0.1 2>/dev/null
		done
		if [ "$_residual" != 0 ]; then
			logger -t eqosplus "WARN residual '$comment' in ${cmd} eqos_forward after delete+retry" 2>/dev/null
			rc=1
		fi
	done
	return $rc
}

# Delete rules whose comment STARTS WITH $1 (prefix substring within --comment).
# Caller must include a trailing delimiter in $1 ('[' for per-rule, ':' for
# bypass) so e.g. "eqos:rule:lan[" won't collide with "eqos:rule:lan2[" — the
# differentiating character anchors the prefix match.
# Same return contract / v4-v6 asymmetry as _eqos_ipt_delete_by_comment,
# but matches a comment PREFIX. Used by the conn_reload purge-then-rebuild
# path (eqos_purge_all_conn) — its 0/1 result decides whether the rebuild
# is allowed to add (purge must be verified clean first, else duplicates).
_eqos_ipt_purge_by_prefix() {
	local prefix=$1
	[ -n "$prefix" ] || return 1
	local cmd save_cmd dump line rc=0 critical _try _residual
	for cmd in iptables ip6tables; do
		save_cmd="${cmd}-save"
		# critical via _eqos_proto_active — IDENTICAL v4/v6 rule, see
		# _eqos_ipt_delete_by_comment.
		_eqos_proto_active "$cmd" && critical=1 || critical=0
		_residual=1
		for _try in 1 2 3; do
			if ! dump=$(_eqos_ipt_save_retry "$save_cmd"); then
				[ "$critical" = 1 ] || { _residual=0; break; }
				[ "$_try" -lt 3 ] && sleep 0.1 2>/dev/null
				continue
			fi
			printf '%s\n' "$dump" | while IFS= read -r line; do
				case "$line" in "-A eqos_forward "*) ;; *) continue ;; esac
				case "$line" in *"--comment \"${prefix}"*) ;; *) continue ;; esac
				eval "$cmd -w 2 -D eqos_forward ${line#-A eqos_forward }" 2>/dev/null
			done
			if dump=$(_eqos_ipt_save_retry "$save_cmd"); then
				if printf '%s\n' "$dump" | grep -F -- '-A eqos_forward ' | grep -qF -- "--comment \"${prefix}"; then
					_residual=1
				else
					_residual=0; break
				fi
			else
				[ "$critical" = 1 ] || { _residual=0; break; }
			fi
			[ "$_try" -lt 3 ] && sleep 0.1 2>/dev/null
		done
		if [ "$_residual" != 0 ]; then
			logger -t eqosplus "WARN residual prefix '$prefix' in ${cmd} eqos_forward after purge+retry" 2>/dev/null
			rc=1
		fi
	done
	return $rc
}

# ---- Backend dispatch ------------------------------------------------------

: ${EQOS_BACKEND:=none}

eqos_init_conn_table()       { case "$EQOS_BACKEND" in nft) eqos_init_conn_table_nft;;       iptables) eqos_init_conn_table_ipt;;       esac; }
eqos_teardown_conn_table()   { case "$EQOS_BACKEND" in nft) eqos_teardown_conn_table_nft;;   iptables) eqos_teardown_conn_table_ipt;;   esac; }
eqos_force_clean_conn_table(){ case "$EQOS_BACKEND" in iptables) eqos_force_clean_conn_table_ipt;; *) return 0 ;; esac; }
eqos_init_conn_network()     { case "$EQOS_BACKEND" in nft) eqos_init_conn_network_nft "$@"; ;; iptables) eqos_init_conn_network_ipt "$@"; ;; esac; }
eqos_teardown_conn_network() { case "$EQOS_BACKEND" in nft) eqos_teardown_conn_network_nft "$@"; ;; iptables) eqos_teardown_conn_network_ipt "$@"; ;; esac; }
eqos_update_bypass_set()     { case "$EQOS_BACKEND" in nft) eqos_update_bypass_set_nft "$@"; ;; iptables) eqos_update_bypass_set_ipt "$@"; ;; esac; }
eqos_add_conn()              { case "$EQOS_BACKEND" in nft) eqos_add_conn_nft "$@"; ;;          iptables) eqos_add_conn_ipt "$@"; ;;          esac; }
eqos_del_conn()              { case "$EQOS_BACKEND" in nft) eqos_del_conn_nft "$@"; ;;          iptables) eqos_del_conn_ipt "$@"; ;;          esac; }
eqos_purge_conn_for_network(){ case "$EQOS_BACKEND" in nft) eqos_purge_conn_for_network_nft "$@"; ;; iptables) eqos_purge_conn_for_network_ipt "$@"; ;; esac; }
# Wipe ALL per-rule connlimit entries (every "eqos:rule:" comment, all
# networks + any orphans). Returns non-zero if the purge could not be
# verified clean — conn_reload's purge-then-rebuild relies on this so it
# only re-adds onto a confirmed-empty chain (structurally zero-duplicate).
eqos_purge_all_conn()        { case "$EQOS_BACKEND" in nft) _eqos_nft_purge_by_prefix "eqos:rule:"; ;; iptables) _eqos_ipt_purge_by_prefix "eqos:rule:"; ;; *) return 0 ;; esac; }

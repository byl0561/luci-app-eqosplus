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

# Delete a rate limit rule (both directions)
# Usage: eqos_del_id <dev> <id>
eqos_del_id() {
	local dev=$1 id=$2
	[ -n "$dev" ] && [ -n "$id" ] || return 1

	$EQOS_TC_QUIET filter del dev "${dev}" parent ffff: prio "$id" 2>/dev/null
	$EQOS_TC_QUIET filter del dev "${dev}_ifb" parent 1:0 prio "$id" 2>/dev/null
	$EQOS_TC_QUIET filter del dev "${dev}" parent 1:0 prio "$id" 2>/dev/null

	$EQOS_TC_QUIET qdisc del dev "${dev}" parent 1:"$id" 2>/dev/null
	$EQOS_TC_QUIET qdisc del dev "${dev}_ifb" parent 1:"$id" 2>/dev/null

	$EQOS_TC_QUIET class del dev "${dev}" parent 1:1 classid 1:"$id" 2>/dev/null
	$EQOS_TC_QUIET class del dev "${dev}_ifb" parent 1:1 classid 1:"$id" 2>/dev/null
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

	# shellcheck disable=SC2086
	nft add rule inet eqosplus forward $match $proto_match ct count over "$limit" reject comment "\"eqos:rule:${rule_id}\"" 2>/dev/null
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
_eqos_nft_delete_by_comment() {
	local comment=$1
	[ -n "$comment" ] || return
	nft -a list chain inet eqosplus forward 2>/dev/null | awk -v c="\"${comment}\"" '
		index($0, c) && match($0, /handle [0-9]+/) {
			print substr($0, RSTART + 7, RLENGTH - 7)
		}
	' | while read -r handle; do
		[ -n "$handle" ] && nft delete rule inet eqosplus forward handle "$handle" 2>/dev/null
	done
	return 0
}

# Delete all rules whose comment STARTS WITH $1 (un-anchored prefix match).
# Pattern must include a trailing delimiter (typically '[' or ':') for
# uniqueness — otherwise "lan" prefix would also match "lan2".
_eqos_nft_purge_by_prefix() {
	local prefix=$1
	[ -n "$prefix" ] || return
	nft -a list chain inet eqosplus forward 2>/dev/null | awk -v p="\"${prefix}" '
		index($0, p) && match($0, /handle [0-9]+/) {
			print substr($0, RSTART + 7, RLENGTH - 7)
		}
	' | while read -r handle; do
		[ -n "$handle" ] && nft delete rule inet eqosplus forward handle "$handle" 2>/dev/null
	done
	return 0
}

# ---- iptables backend ------------------------------------------------------

eqos_init_conn_table_ipt() {
	iptables  -nL eqos_forward >/dev/null 2>&1 || iptables  -N eqos_forward 2>/dev/null
	ip6tables -nL eqos_forward >/dev/null 2>&1 || ip6tables -N eqos_forward 2>/dev/null
	iptables  -C FORWARD -j eqos_forward 2>/dev/null || iptables  -I FORWARD 1 -j eqos_forward 2>/dev/null
	ip6tables -C FORWARD -j eqos_forward 2>/dev/null || ip6tables -I FORWARD 1 -j eqos_forward 2>/dev/null
}

eqos_teardown_conn_table_ipt() {
	iptables  -D FORWARD -j eqos_forward 2>/dev/null
	ip6tables -D FORWARD -j eqos_forward 2>/dev/null
	iptables  -F eqos_forward 2>/dev/null
	iptables  -X eqos_forward 2>/dev/null
	ip6tables -F eqos_forward 2>/dev/null
	ip6tables -X eqos_forward 2>/dev/null
	# Destroy any leftover ipsets
	local s
	for s in $(ipset list -name 2>/dev/null | grep '^eqos_bypass'); do
		ipset destroy "$s" 2>/dev/null
	done
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
	iptables -C eqos_forward -i "$dev" -m set --match-set "eqos_bypass4_${network}" dst \
		-m comment --comment "eqos:bypass:${network}:" -j RETURN 2>/dev/null || \
	iptables -I eqos_forward 1 -i "$dev" -m set --match-set "eqos_bypass4_${network}" dst \
		-m comment --comment "eqos:bypass:${network}:" -j RETURN 2>/dev/null
	ip6tables -C eqos_forward -i "$dev" -m set --match-set "eqos_bypass6_${network}" dst \
		-m comment --comment "eqos:bypass:${network}:" -j RETURN 2>/dev/null || \
	ip6tables -I eqos_forward 1 -i "$dev" -m set --match-set "eqos_bypass6_${network}" dst \
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
		iptables -A eqos_forward -m mac --mac-source "$addr" $proto_args \
			-m connlimit --connlimit-above "$limit" --connlimit-mask 32 $connlimit_side \
			-m comment --comment "eqos:rule:${rule_id}" -j REJECT 2>/dev/null
		# shellcheck disable=SC2086
		ip6tables -A eqos_forward -m mac --mac-source "$addr" $proto_args \
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
		ip6tables -A eqos_forward $addr_flag "$addr" $proto_args \
			-m connlimit --connlimit-above "$limit" --connlimit-mask "$prefix" $connlimit_side \
			-m comment --comment "eqos:rule:${rule_id}" -j REJECT 2>/dev/null
	else
		# shellcheck disable=SC2086
		iptables -A eqos_forward $addr_flag "$addr" $proto_args \
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

# Delete rules whose comment EXACTLY equals $1.
# We use iptables-save (stable, machine-readable output) instead of iptables -L
# because -L's rendering of -m comment varies across builds: some show
# "/* x */", some bare, some omit it entirely without -v. iptables-save always
# emits "--comment "x"" (double-quoted, no wrapper) per rule, one rule per line
# starting with "-A <chain>", so we can count chain index reliably.
_eqos_ipt_delete_by_comment() {
	local comment=$1
	[ -n "$comment" ] || return
	local cmd save_cmd lns ln
	for cmd in iptables ip6tables; do
		save_cmd="${cmd}-save"
		lns=$($save_cmd 2>/dev/null | awk -v c="$comment" '
			/^-A eqos_forward / {
				idx++
				if (index($0, "--comment \"" c "\"")) print idx
			}
		' | sort -rn)
		for ln in $lns; do
			$cmd -D eqos_forward "$ln" 2>/dev/null
		done
	done
	return 0
}

# Delete rules whose comment STARTS WITH $1 (prefix substring within --comment).
# Caller must include a trailing delimiter in $1 ('[' for per-rule, ':' for
# bypass) so e.g. "eqos:rule:lan[" won't collide with "eqos:rule:lan2[" — the
# differentiating character anchors the prefix match.
_eqos_ipt_purge_by_prefix() {
	local prefix=$1
	[ -n "$prefix" ] || return
	local cmd save_cmd lns ln
	for cmd in iptables ip6tables; do
		save_cmd="${cmd}-save"
		lns=$($save_cmd 2>/dev/null | awk -v p="$prefix" '
			/^-A eqos_forward / {
				idx++
				if (index($0, "--comment \"" p)) print idx
			}
		' | sort -rn)
		for ln in $lns; do
			$cmd -D eqos_forward "$ln" 2>/dev/null
		done
	done
	return 0
}

# ---- Backend dispatch ------------------------------------------------------

: ${EQOS_BACKEND:=none}

eqos_init_conn_table()       { case "$EQOS_BACKEND" in nft) eqos_init_conn_table_nft;;       iptables) eqos_init_conn_table_ipt;;       esac; }
eqos_teardown_conn_table()   { case "$EQOS_BACKEND" in nft) eqos_teardown_conn_table_nft;;   iptables) eqos_teardown_conn_table_ipt;;   esac; }
eqos_init_conn_network()     { case "$EQOS_BACKEND" in nft) eqos_init_conn_network_nft "$@"; ;; iptables) eqos_init_conn_network_ipt "$@"; ;; esac; }
eqos_teardown_conn_network() { case "$EQOS_BACKEND" in nft) eqos_teardown_conn_network_nft "$@"; ;; iptables) eqos_teardown_conn_network_ipt "$@"; ;; esac; }
eqos_update_bypass_set()     { case "$EQOS_BACKEND" in nft) eqos_update_bypass_set_nft "$@"; ;; iptables) eqos_update_bypass_set_ipt "$@"; ;; esac; }
eqos_add_conn()              { case "$EQOS_BACKEND" in nft) eqos_add_conn_nft "$@"; ;;          iptables) eqos_add_conn_ipt "$@"; ;;          esac; }
eqos_del_conn()              { case "$EQOS_BACKEND" in nft) eqos_del_conn_nft "$@"; ;;          iptables) eqos_del_conn_ipt "$@"; ;;          esac; }
eqos_purge_conn_for_network(){ case "$EQOS_BACKEND" in nft) eqos_purge_conn_for_network_nft "$@"; ;; iptables) eqos_purge_conn_for_network_ipt "$@"; ;; esac; }

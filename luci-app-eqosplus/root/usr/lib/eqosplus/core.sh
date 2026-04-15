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

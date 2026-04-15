#!/bin/sh
# eqosplus IDLIST & file operations - shared by main script and tests
# All functions use $EQOS_MKTEMP and $EQOS_LOG for dependency injection:
#   Main script: defaults to safe_mktemp / log_msg (no setup needed)
#   Tests: set EQOS_MKTEMP=_test_mktemp EQOS_LOG=: before sourcing

: ${EQOS_MKTEMP:=safe_mktemp}
: ${EQOS_LOG:=log_msg}

# Safely remove exact lines from a file (atomic via tmpfile, fixed-string match)
# Usage: _file_remove_exact_line <file> <pattern>
# Uses grep -vFx internally — pattern is always treated as a literal fixed string.
# For IDLIST network-prefix removal, use _idlist_remove_network instead.
_file_remove_exact_line() {
	local file=$1 pattern=$2
	local tmpf
	tmpf=$($EQOS_MKTEMP) || return 1
	grep -vFx "$pattern" "$file" > "$tmpf" 2>/dev/null
	case $? in 0|1) mv "$tmpf" "$file" || { rm -f "$tmpf"; $EQOS_LOG 1 "mv failed updating $file"; return 1; } ;; *) rm -f "$tmpf"; $EQOS_LOG 1 "grep failed updating $file" ;; esac
}

# Remove all IDLIST entries for a given network (safe fixed-string prefix match)
# IDLIST format: "network[rule_id]:device" per line, e.g. "lan[0]:br-lan", "guest[3]:br-guest"
# Prefix match on "network[" still works because ":device" comes after "[id]".
# Usage: _idlist_remove_network <network>
_idlist_remove_network() {
	local net=$1
	local tmpf
	tmpf=$($EQOS_MKTEMP) || return 1
	awk -v prefix="${net}[" 'substr($0, 1, length(prefix)) != prefix' "$IDLIST" > "$tmpf" 2>/dev/null
	case $? in 0|1) mv "$tmpf" "$IDLIST" || { rm -f "$tmpf"; $EQOS_LOG 1 "mv failed updating $IDLIST"; return 1; } ;; *) rm -f "$tmpf"; $EQOS_LOG 1 "awk failed updating $IDLIST" ;; esac
}

# Get the stored device for a rule ID from IDLIST
# Usage: _idlist_get_device <rule_id>  →  outputs device name or empty
# Uses awk prefix match (not grep -F substring) to avoid false hits
# e.g. "lan[0]:" must not match "wlan[0]:br-wlan".
_idlist_get_device() {
	awk -v prefix="$1:" 'substr($0, 1, length(prefix)) == prefix { sub(/^[^:]*:/, ""); print; exit }' "$IDLIST" 2>/dev/null
}

# Remove an IDLIST entry by rule ID (matches "id:*" regardless of device suffix)
# Usage: _idlist_remove_entry <rule_id>
_idlist_remove_entry() {
	local id=$1
	local tmpf
	tmpf=$($EQOS_MKTEMP) || return 1
	awk -v prefix="${id}:" 'substr($0, 1, length(prefix)) != prefix' "$IDLIST" > "$tmpf" 2>/dev/null
	case $? in 0|1) mv "$tmpf" "$IDLIST" || { rm -f "$tmpf"; $EQOS_LOG 1 "mv failed updating $IDLIST"; return 1; } ;; *) rm -f "$tmpf"; $EQOS_LOG 1 "awk failed updating $IDLIST" ;; esac
}

# Add an entry to IDLIST with device info (replaces any existing entry for same ID)
# Usage: _idlist_add_entry <rule_id> <device>
_idlist_add_entry() {
	local id=$1 dev=$2
	_idlist_remove_entry "$id"
	local tmpf
	tmpf=$($EQOS_MKTEMP) || return 1
	{ cat "$IDLIST" 2>/dev/null; echo "${id}:${dev}"; } | sort -u > "$tmpf" \
		&& mv "$tmpf" "$IDLIST" \
		|| { $EQOS_LOG 1 "_idlist_add_entry: failed to update $IDLIST"; rm -f "$tmpf"; return 1; }
}

#!/bin/sh
# eqosplus schedule check - shared by daemon and tests
# Pure function: no side effects, no UCI dependency.

# Check if a schedule rule is active at a given time/weekday
# Usage: check_item <id> <timestart> <timeend> <weekdays> <cur_h> <cur_m> <cur_weekday>
# Returns 0 if active, 1 if inactive
check_item() {
	local id=$1 start_time=$2 end_time=$3 wweek=$4
	local cur_h=$5 cur_m=$6 current_weekday=$7

	# Convert HH:MM to seconds since midnight (BusyBox compatible, no date -d)
	local start_seconds end_seconds current_time
	if [ -z "$start_time" ] && [ -z "$end_time" ]; then
		# No time constraint, skip time check
		:
	elif [ "$start_time" = "00:00" ] && [ "$end_time" = "00:00" ]; then
		# Both zero means always active, skip time check
		:
	else
		start_h=${start_time%%:*}
		start_m=${start_time##*:}
		end_h=${end_time%%:*}
		end_m=${end_time##*:}
		# Guard against malformed time values (validate raw, strip leading 0 only for arithmetic)
		case "$start_h" in ''|*[!0-9]*) return 1 ;; esac
		case "$start_m" in ''|*[!0-9]*) return 1 ;; esac
		case "$end_h"   in ''|*[!0-9]*) return 1 ;; esac
		case "$end_m"   in ''|*[!0-9]*) return 1 ;; esac
		# Strip single leading 0 to avoid octal interpretation (`08` → arith
		# error in busybox ash). For lone-"0" inputs the strip leaves an
		# empty string, which itself errors `$(("" * N))` and on some
		# busybox builds aborts the whole script — defaulting back to "0"
		# via :- keeps the arithmetic well-formed for "0:00" / "0:30" etc.
		_sh=${start_h#0}; _sh=${_sh:-0}
		_sm=${start_m#0}; _sm=${_sm:-0}
		_eh=${end_h#0};   _eh=${_eh:-0}
		_em=${end_m#0};   _em=${_em:-0}
		_ch=${cur_h#0};   _ch=${_ch:-0}
		_cm=${cur_m#0};   _cm=${_cm:-0}
		start_seconds=$((_sh * 3600 + _sm * 60))
		end_seconds=$((_eh * 3600 + _em * 60))
		current_time=$((_ch * 3600 + _cm * 60))

		# Zero-width time window (e.g. 09:00-09:00): treat as inactive.
		# UI validation prevents this (start==end disallowed unless 00:00==00:00).
		# This is a defensive fallback — if reached, returning inactive is safest.
		if [ "$start_seconds" -eq "$end_seconds" ] && [ "$start_seconds" -ne 0 ]; then
			return 1
		fi
		if [ "$start_seconds" -ge "$end_seconds" ]; then
			# Cross-midnight (e.g., 23:00-06:00): inactive if between end and start
			if [ "$current_time" -lt "$start_seconds" ] && [ "$current_time" -ge "$end_seconds" ]; then
				return 1
			fi
		else
			# Same day (e.g., 08:00-18:00): inactive if outside [start, end)
			if [ "$current_time" -lt "$start_seconds" ] || [ "$current_time" -ge "$end_seconds" ]; then
				return 1
			fi
		fi
	fi

	# For cross-midnight rules, if we're in the post-midnight portion (before end_time),
	# the rule was started on the previous day — adjust weekday for comparison
	local effective_weekday="$current_weekday"
	if [ -n "$start_time" ] && [ -n "$end_time" ] \
		&& [ "$start_time" != "00:00" ] && [ "$end_time" != "00:00" ] \
		&& [ "$start_seconds" -ge "$end_seconds" ] \
		&& [ "$current_time" -le "$end_seconds" ]; then
		effective_weekday=$((current_weekday - 1))
		[ "$effective_weekday" -eq 0 ] && effective_weekday=7
	fi

	# Empty week means no day-of-week restriction (always active)
	[ -z "$wweek" ] && return 0
	local _oifs="$IFS"; IFS=,; set -f
	for ww in $wweek; do
		IFS="$_oifs"; set +f
		case "$ww" in ''|*[!0-9]*) continue ;; esac
		if [ "$effective_weekday" -eq "$ww" ] || [ "x0" = "x$ww" ]; then
			return 0
		fi
	done
	IFS="$_oifs"; set +f
	return 1
}

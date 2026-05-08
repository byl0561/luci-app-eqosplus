#!/bin/sh
# eqosplus shared UCI helpers - sourced by eqosplus and eqosplusctrl
# No side effects on source; only defines functions.

# Strip UCI quoting from a value: handle 'val', 'v1' 'v2', and '\'' escapes
# Usage: echo "$line" | _uci_unquote
_uci_unquote() {
	awk '{
		sub(/[^=]*=/, "")
		gsub(/\047\\\047\047/, "\001")
		gsub(/\047/, "")
		gsub(/\001/, "\047")
		print
	}'
}

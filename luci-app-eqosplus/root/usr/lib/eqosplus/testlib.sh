#!/bin/sh
# eqosplus test library - shared by eqosplus_test and eqosplus_traffic_test
# Provides: assert, assert_fail, tc_has, test_report, PASS/FAIL/TOTAL counters

PASS=0; FAIL=0; TOTAL=0

assert() {
	local name="$1"; shift
	TOTAL=$((TOTAL + 1))
	if "$@" >/dev/null 2>&1; then
		echo "PASS: $name"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $name"
		FAIL=$((FAIL + 1))
	fi
}

assert_fail() {
	local name="$1"; shift
	TOTAL=$((TOTAL + 1))
	if ! "$@" >/dev/null 2>&1; then
		echo "PASS: $name"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $name"
		FAIL=$((FAIL + 1))
	fi
}

# Verify a tc object exists by checking output contains $PATTERN
tc_has() {
	tc "$@" 2>/dev/null | grep -q "$PATTERN"
}

# Assert file content matches expected string
# Usage: assert_file_content "test name" "expected" "filepath"
assert_file_content() {
	local name=$1 expected=$2 filepath=$3
	local actual
	actual=$(cat "$filepath" 2>/dev/null)
	TOTAL=$((TOTAL + 1))
	if [ "$actual" = "$expected" ]; then
		echo "PASS: $name"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $name"
		echo "  expected: $(echo "$expected" | tr '\n' '|')"
		echo "  actual:   $(echo "$actual" | tr '\n' '|')"
		FAIL=$((FAIL + 1))
	fi
}

# Print final test report and exit with appropriate code
test_report() {
	echo ""
	echo "========================"
	echo "Total: $TOTAL  Pass: $PASS  Fail: $FAIL"
	[ $FAIL -eq 0 ] && echo "ALL PASSED" || echo "SOME FAILED"
}

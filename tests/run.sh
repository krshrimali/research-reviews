#!/usr/bin/env bash
# Run the whole review.nvim test suite headless.
set -uo pipefail
cd "$(dirname "$0")/.."

INIT=tests/minimal_init.lua
SPECS=(anchor_spec source_spec contract_spec runner_spec ui_spec compose_spec regress_spec menu_spec list_spec)
fail=0

for s in "${SPECS[@]}"; do
  echo "=== $s ==="
  out=$(nvim --headless -i NONE -u "$INIT" -c "PlenaryBustedFile tests/$s.lua" 2>&1)
  echo "$out" | grep -E "Success:|Failed :|Errors :" | tr -d '\t'
  if echo "$out" | grep -qE "Failed : *[1-9]|Errors : *[1-9]|Tests Failed"; then
    fail=1
    echo "$out" | grep -iE "fail|error" | grep -v "Failed : 0\|Errors : 0" | head -5
  fi
done

for standalone in full_flow features; do
  echo "=== $standalone (standalone) ==="
  out=$(nvim --headless -i NONE -u "$INIT" -l "tests/$standalone.lua" 2>&1 | grep -vE "devicons|nvim.log")
  echo "$out" | grep -E "ok |FAIL|PASSED|FAILED"
  if echo "$out" | grep -q "FAILED"; then fail=1; fi
done

echo
[ "$fail" -eq 0 ] && echo "SUITE: GREEN" || echo "SUITE: RED"
exit $fail

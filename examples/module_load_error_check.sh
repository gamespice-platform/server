#!/usr/bin/env bash
#
# A module whose game scripts no longer compile fails to load with the parse error named in the
# result (examples/module_load_error_probe.gd). Not a suite: the fixture prints a real Parse
# Error on purpose, which the suite runner fails any suite for.
#
#   examples/module_load_error_check.sh     exit 0 when every check passes, 1 otherwise
#
# Arm it by making DotModuleHost.with_script_errors return `failed` unchanged: three checks fail.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
out=$(timeout 120 "${GODOT:-godot}" --headless --path . res://examples/module_load_error_probe.tscn 2>&1)
status=$?
printf '%s\n' "$out" | grep -E '^module_load_error:|^  (ok|FAIL) '
fails=0
if ! grep -q 'Cannot infer the type of "net_id"' <<<"$out"; then
    echo "  FAIL the engine never reported the fixture's parse error, so this did not test anything"; fails=$((fails + 1))
fi
if ! grep -q '^module_load_error: 0 failed' <<<"$out" || [ "$status" -ne 0 ]; then
    echo "  FAIL the probe exited $status"; fails=$((fails + 1))
fi
echo "module_load_error_check: $fails failed"
exit $(( fails > 0 ))

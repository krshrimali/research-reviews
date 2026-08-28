#!/usr/bin/env bash
# Run the prtui test suite (data layer + headless UI import/screenshot smoke).
set -uo pipefail
cd "$(dirname "$0")/.."
PY=./.venv/bin/python
fail=0

echo "=== module imports ==="
$PY -c "
import importlib
for m in ['prtui.data.proc','prtui.data.git','prtui.data.gh','prtui.data.source','prtui.data.store','prtui.data.claude','prtui.data.github_sync','prtui.widgets.vim','prtui.widgets.render','prtui.widgets.diff_view','prtui.screens.modals','prtui.screens.review','prtui.screens.source_list','prtui.app','prtui.__main__']:
    importlib.import_module(m)
print('all modules import OK')
" || fail=1

echo "=== data layer ==="
$PY tests/test_data.py || fail=1

echo "=== headless UI (render + screenshots) ==="
$PY tests/shots.py >/dev/null 2>&1 && echo "UI rendered 4 screens OK" || { echo "UI FAILED"; fail=1; }

echo
[ "$fail" -eq 0 ] && echo "PRTUI SUITE: GREEN" || echo "PRTUI SUITE: RED"
exit $fail

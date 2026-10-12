#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
SESSION="hermes-termux-test-$$"
ab() { agent-browser --session "$SESSION" "$@"; }
trap 'ab close >/dev/null 2>&1 || true' EXIT
ab open 'data:text/html,<title>Hermes Termux smoke</title><button onclick="this.textContent=123">Click me</button>'
ab get title | grep -F 'Hermes Termux smoke'
ab snapshot -i
ab click 'button'
ab get text 'button' | grep -F '123'

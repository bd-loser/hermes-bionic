#!/data/data/com.termux/files/usr/bin/bash
# Usage: bash browser/install.sh /path/to/verified/actions-artifact-directory
set -euo pipefail
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ARTIFACT="${1:?pass the extracted agent-browser Actions artifact directory}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ "$(uname -m)" = aarch64 ] || { echo 'Requires aarch64 Termux' >&2; exit 1; }
[ -s "$ARTIFACT/agent-browser-android-arm64" ]
(cd "$ARTIFACT" && sha256sum -c agent-browser-android-arm64.sha256)
"$ARTIFACT/agent-browser-android-arm64" --version
command -v chromium-browser >/dev/null || {
  echo 'Install Chromium first: pkg install x11-repo && pkg install chromium' >&2
  exit 1
}
install -Dm755 "$ARTIFACT/agent-browser-android-arm64" "$PREFIX/libexec/hermes-bionic/agent-browser"
# Replace the npm symlink itself, never follow it into the npm package.
install -m755 "$HERE/agent-browser" "$PREFIX/bin/agent-browser.hermes-new"
mv -f "$PREFIX/bin/agent-browser.hermes-new" "$PREFIX/bin/agent-browser"
printf '\nHermes browser environment (add to ~/.hermes/.env):\nAGENT_BROWSER_EXECUTABLE_PATH=%s/bin/chromium-browser\n' "$PREFIX"
"$PREFIX/bin/agent-browser" --version

#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
task_tmp="$(mktemp -d /private/tmp/dayday-browser-bridge-test.XXXXXX)"
trap 'rm -rf "$task_tmp"' EXIT

zsh -n "$repo_root/scripts/install-browser-bridge.sh"
node --check "$repo_root/BrowserExtension/service-worker.js"

mkdir -p "$task_tmp/module-cache"
export CLANG_MODULE_CACHE_PATH="$task_tmp/module-cache"
xcrun swiftc "$repo_root/Tools/DaydayBrowserHost/main.swift" -o "$task_tmp/dayday-browser-host"

node -e '
  const message = Buffer.from(JSON.stringify({ protocolVersion: 1, sequence: 1, bridgeReady: true, incognito: false }));
  const header = Buffer.alloc(4); header.writeUInt32LE(message.length); process.stdout.write(Buffer.concat([header, message]));
' | "$task_tmp/dayday-browser-host" --browser-bundle-id com.google.chrome --state-directory "$task_tmp/state" > "$task_tmp/reply"

node -e '
  const fs = require("fs");
  const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const reply = fs.readFileSync(process.argv[2]);
  if (state.protocolVersion !== 1 || state.bridgeReady !== true || state.incognito !== false) process.exit(1);
  if (reply.readUInt32LE(0) > 4096 || JSON.parse(reply.subarray(4)).accepted !== true) process.exit(1);
' "$task_tmp/state/com.google.chrome.json" "$task_tmp/reply"

fixture_apps="$task_tmp/Applications"
fixture_home="$task_tmp/Home"
make_browser_fixture() {
  local application_name="$1"
  local bundle_id="$2"
  local info="$fixture_apps/$application_name/Contents/Info.plist"
  mkdir -p "${info:h}"
  plutil -create xml1 "$info"
  plutil -replace CFBundleIdentifier -string "$bundle_id" "$info"
}

make_browser_fixture "Google Chrome.app" "com.google.Chrome"
make_browser_fixture "Tabbit Browser.app" "com.tab-browser.Tabbit"
DAYDAY_BROWSER_BRIDGE_HOME="$fixture_home" \
  DAYDAY_BROWSER_BRIDGE_SYSTEM_APPLICATIONS="$fixture_apps" \
  DAYDAY_BROWSER_BRIDGE_USER_APPLICATIONS="$task_tmp/NoUserApplications" \
  "$repo_root/scripts/install-browser-bridge.sh" --install > "$task_tmp/install-output"
DAYDAY_BROWSER_BRIDGE_HOME="$fixture_home" \
  DAYDAY_BROWSER_BRIDGE_SYSTEM_APPLICATIONS="$fixture_apps" \
  DAYDAY_BROWSER_BRIDGE_USER_APPLICATIONS="$task_tmp/NoUserApplications" \
  "$repo_root/scripts/install-browser-bridge.sh" --check > "$task_tmp/check-output" || {
    sed -n '1,120p' "$task_tmp/check-output" >&2
    exit 1
  }
grep -Fq "Browser installed: com.google.Chrome" "$task_tmp/check-output"
grep -Fq "Browser installed: com.tab-browser.Tabbit" "$task_tmp/check-output"
grep -Fq "Manifest relationship: matched" "$task_tmp/check-output"

spoof_apps="$task_tmp/SpoofApplications"
fixture_apps="$spoof_apps"
make_browser_fixture "Google Chrome.app" "com.google.chrome"
if DAYDAY_BROWSER_BRIDGE_HOME="$fixture_home" \
  DAYDAY_BROWSER_BRIDGE_SYSTEM_APPLICATIONS="$spoof_apps" \
  DAYDAY_BROWSER_BRIDGE_USER_APPLICATIONS="$task_tmp/NoUserApplications" \
  "$repo_root/scripts/install-browser-bridge.sh" --check > /dev/null 2>&1; then
  print -u2 "Spoofed browser bundle identifier was accepted."
  exit 1
fi

print "Browser bridge asset self-test passed. No browser was launched."

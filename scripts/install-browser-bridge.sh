#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
user_home="${DAYDAY_BROWSER_BRIDGE_HOME:-$HOME}"
system_applications="${DAYDAY_BROWSER_BRIDGE_SYSTEM_APPLICATIONS:-/Applications}"
user_applications="${DAYDAY_BROWSER_BRIDGE_USER_APPLICATIONS:-$user_home/Applications}"
support_root="$user_home/Library/Application Support/Dayday/BrowserBridge"
binary_path="$support_root/dayday-browser-host"
extension_id="ifgffomkndghdipdhalahilpfffkfclm"
host_name="app.dayday.browser_bridge"

usage() {
  print "Usage: ${0:t} --install | --check"
  print "  --install  Compile the local host and install manifests for detected browsers."
  print "  --check    Read-only self-check; does not launch a browser or change browser settings."
}

[[ $# -eq 1 ]] || { usage >&2; exit 64; }
mode="$1"
[[ "$mode" == "--install" || "$mode" == "--check" ]] || { usage >&2; exit 64; }

typeset -a browser_bundle_ids browser_host_bundle_ids browser_manifest_roots browser_app_paths
browser_bundle_ids=()
browser_host_bundle_ids=()
browser_manifest_roots=()
browser_app_paths=()

register_browser() {
  local expected_bundle_id="$1"
  local manifest_subpath="$2"
  shift 3
  local candidate
  for candidate in "$@"; do
    [[ -d "$candidate" ]] || continue
    local info="$candidate/Contents/Info.plist"
    [[ -f "$info" ]] || continue
    local bundle_id
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info" 2>/dev/null || true)"
    [[ "$bundle_id" == "$expected_bundle_id" ]] || continue
    browser_bundle_ids+=("$bundle_id")
    browser_host_bundle_ids+=("${bundle_id:l}")
    browser_manifest_roots+=("$user_home/Library/Application Support/$manifest_subpath/NativeMessagingHosts")
    browser_app_paths+=("$candidate")
    return
  done
}

register_browser "com.google.Chrome" "Google/Chrome" "Google Chrome.app" \
  "$system_applications/Google Chrome.app" "$user_applications/Google Chrome.app"
register_browser "com.tab-browser.Tabbit" "Tabbit Browser" "Tabbit Browser.app" \
  "$system_applications/Tabbit Browser.app" "$user_applications/Tabbit Browser.app"

[[ ${#browser_bundle_ids[@]} -gt 0 ]] || {
  print -u2 "No supported Google Chrome or Tabbit installation was found in $system_applications or $user_applications."
  exit 69
}

install_manifest() {
  local browser_directory="$1"
  local browser_bundle_id="$2"
  local wrapper_path="$support_root/host-$browser_bundle_id"
  mkdir -p "$browser_directory"
  chmod 700 "$browser_directory"
  print '#!/bin/zsh' > "$wrapper_path"
  print -r -- "exec ${(q)binary_path} --browser-bundle-id ${(q)browser_bundle_id}" >> "$wrapper_path"
  chmod 700 "$wrapper_path"
  local manifest_path="$browser_directory/$host_name.json"
  {
    print '{'
    print -r -- "  \"name\": \"$host_name\","
    print '  "description": "Dayday local browser safety bridge",'
    print -r -- "  \"path\": \"$wrapper_path\","
    print '  "type": "stdio",'
    print -r -- "  \"allowed_origins\": [\"chrome-extension://$extension_id/\"]"
    print '}'
  } > "$manifest_path"
  chmod 600 "$manifest_path"
}

if [[ "$mode" == "--install" ]]; then
  mkdir -p "$support_root"
  chmod 700 "$support_root"
  xcrun swiftc "$repo_root/Tools/DaydayBrowserHost/main.swift" -o "$binary_path"
  chmod 700 "$binary_path"
  integer index
  for ((index = 1; index <= ${#browser_bundle_ids[@]}; index++)); do
    install_manifest "$browser_manifest_roots[$index]" "$browser_host_bundle_ids[$index]"
  done
fi

extension_manifest="$repo_root/BrowserExtension/manifest.json"
extension_manifest_status="missing"
[[ -f "$extension_manifest" ]] && extension_manifest_status="present"
print "Extension manifest: $extension_manifest_status ($extension_manifest)"

integer check_failed=0
integer index
for ((index = 1; index <= ${#browser_bundle_ids[@]}; index++)); do
  manifest_path="$browser_manifest_roots[$index]/$host_name.json"
  wrapper_path="$support_root/host-$browser_host_bundle_ids[$index]"
  print "Browser installed: ${browser_bundle_ids[$index]} (${browser_app_paths[$index]})"
  if [[ -f "$manifest_path" ]]; then
    print "  Native host manifest: present ($manifest_path)"
  else
    print "  Native host manifest: missing ($manifest_path)"
    check_failed=1
  fi
  if [[ -x "$binary_path" ]]; then
    print "  Compiled host: present ($binary_path)"
  else
    print "  Compiled host: missing ($binary_path)"
    check_failed=1
  fi
  if [[ -x "$wrapper_path" ]] && grep -Fq -- "dayday-browser-host" "$wrapper_path" && \
    grep -Fq -- "--browser-bundle-id $browser_host_bundle_ids[$index]" "$wrapper_path"; then
    print "  Host wrapper: present and matched ($wrapper_path)"
  else
    print "  Host wrapper: missing or mismatched ($wrapper_path)"
    check_failed=1
  fi
  if [[ -f "$manifest_path" ]] && grep -Fq -- "\"path\": \"$wrapper_path\"" "$manifest_path" && \
    grep -Fq -- "\"name\": \"$host_name\"" "$manifest_path" && \
    grep -Fq -- "chrome-extension://$extension_id/" "$manifest_path"; then
    print "  Manifest relationship: matched"
  else
    print "  Manifest relationship: missing or mismatched"
    check_failed=1
  fi
done

if [[ "$mode" == "--install" ]]; then
  print "Browser bridge installed. Load unpacked extension from: $repo_root/BrowserExtension"
  print "Expected extension ID: $extension_id"
  print "Do not enable extension access in incognito; incognito remains fail-closed."
else
  [[ "$extension_manifest_status" == "present" ]] || check_failed=1
  if (( check_failed )); then
    print -u2 "Browser bridge self-check found missing or mismatched local installation artifacts."
    exit 1
  fi
  print "Browser bridge self-check passed. No browser was launched or browser setting changed."
fi

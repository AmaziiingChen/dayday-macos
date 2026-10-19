#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
acceptance_bundle_identifier=app.dayday.local.ui-acceptance
acceptance_derived_data_path="$project_dir/.build/xcode-derived-ui-acceptance"
temporary_root=${TMPDIR:-/private/tmp}
acceptance_home=$(/usr/bin/mktemp -d "$temporary_root/dayday-ui-acceptance.XXXXXX")
acceptance_application_support="$acceptance_home/Library/Application Support"

/bin/mkdir -p "$acceptance_application_support"
/bin/chmod 700 "$acceptance_home" "$acceptance_home/Library" "$acceptance_application_support"

DAYDAY_BUNDLE_IDENTIFIER="$acceptance_bundle_identifier" \
DAYDAY_DERIVED_DATA_PATH="$acceptance_derived_data_path" \
  "$script_dir/build-local-app.sh"

app_path="$acceptance_derived_data_path/Build/Products/Debug/Dayday.app"
if [[ ! -d "$app_path" ]]; then
  print -u2 "Dayday UI 验收构建未生成应用包：$app_path"
  exit 1
fi

actual_bundle_identifier=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
if [[ "$actual_bundle_identifier" != "$acceptance_bundle_identifier" ]]; then
  print -u2 "Dayday UI 验收构建身份不正确；没有启动应用。"
  exit 1
fi

# LaunchServices admits this separate bundle beside the production Dayday. CFFIXED_USER_HOME
# redirects every standard user-domain Application Support lookup before the process starts, so
# the acceptance instance cannot open ~/Library/Application Support/Dayday/dayday.sqlite3.
/usr/bin/open -n "$app_path" \
  --env "CFFIXED_USER_HOME=$acceptance_home" \
  --env "DAYDAY_UI_ACCEPTANCE=1"

print "Dayday UI 验收实例已使用独立身份启动。"
print "验收 Application Support：$acceptance_application_support"
print "验收数据库：$acceptance_application_support/Dayday/dayday.sqlite3"

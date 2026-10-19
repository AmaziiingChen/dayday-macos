#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
derived_data_path=${DAYDAY_DERIVED_DATA_PATH:-"$project_dir/.build/xcode-derived-signed"}
output_dir="$project_dir/.build/distribution"
app_path="$derived_data_path/Build/Products/Release/Dayday.app"
archive_path="$output_dir/Dayday-macOS-arm64.zip"
disk_image_path="$output_dir/Dayday-macOS-arm64.dmg"
image_root=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/dayday-package.XXXXXX")
trap '/bin/rm -rf "$image_root"' EXIT

DAYDAY_BUILD_CONFIGURATION=Release DAYDAY_SIGNING_MODE=adhoc \
  "$script_dir/build-local-app.sh"

mkdir -p "$output_dir"
/usr/bin/codesign --verify --deep --strict "$app_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
/usr/bin/ditto "$app_path" "$image_root/Dayday.app"
/bin/ln -s /Applications "$image_root/Applications"
/usr/bin/hdiutil create -volname Dayday -srcfolder "$image_root" \
  -ov -format UDZO "$disk_image_path"
(
  cd "$output_dir"
  /usr/bin/shasum -a 256 Dayday-macOS-arm64.zip Dayday-macOS-arm64.dmg > SHA256SUMS.txt
)
print "Release app: $app_path"
print "Installer: $disk_image_path"
print "Archive: $archive_path"

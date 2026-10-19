#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
derived_data_path=${DAYDAY_DERIVED_DATA_PATH:-"$project_dir/.build/xcode-derived-signed"}
build_configuration=${DAYDAY_BUILD_CONFIGURATION:-Debug}
signing_mode=${DAYDAY_SIGNING_MODE:-local}
if [[ "$build_configuration" != Debug && "$build_configuration" != Release ]]; then
  print -u2 "DAYDAY_BUILD_CONFIGURATION must be Debug or Release."
  exit 1
fi
if [[ "$signing_mode" != local && "$signing_mode" != adhoc ]]; then
  print -u2 "DAYDAY_SIGNING_MODE must be local or adhoc."
  exit 1
fi
app_path="$derived_data_path/Build/Products/$build_configuration/Dayday.app"
bundle_identifier=${DAYDAY_BUNDLE_IDENTIFIER:-app.dayday.local}

if [[ ! "$bundle_identifier" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$' ]]; then
  print -u2 "Invalid Dayday bundle identifier: $bundle_identifier"
  exit 1
fi

cd "$project_dir"

if [[ "$(xcode-select -p)" == */CommandLineTools ]]; then
  print "Building with Swift Package Manager (Command Line Tools)."
  # The macOS 27 SDK requires SwiftUI macro plugins absent from standalone CLT.
  swift_sdk_path=${DAYDAY_SWIFT_SDK_PATH:-"$(xcode-select -p)/SDKs/MacOSX26.sdk"}
  if [[ ! -d "$swift_sdk_path" ]]; then
    print -u2 "Missing macOS 26 SDK. Install it or set DAYDAY_SWIFT_SDK_PATH to a compatible SDK."
    exit 1
  fi
  swift_sdk_path="$(cd "$swift_sdk_path" && pwd -P)"
  # Swift 6.4 defaults to an engine that invokes Xcode's asset compiler.
  # The native engine can compile this package using the standalone macOS SDK.
  swift_flags=()
  if [[ "$build_configuration" == Release ]]; then
    swift_flags=(-Xswiftc -file-prefix-map -Xswiftc "$project_dir=/src/Dayday")
  fi
  swift build --build-system native --configuration "${build_configuration:l}" \
    --product DaydayApp --jobs 4 --sdk "$swift_sdk_path" "${swift_flags[@]}"
  swift_bin_path="$(swift build --build-system native --configuration "${build_configuration:l}" --show-bin-path --sdk "$swift_sdk_path")"
  mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
  cp "$swift_bin_path/DaydayApp" "$app_path/Contents/MacOS/Dayday"
  ditto Sources/DaydayApp/Resources/MarkEdit "$app_path/Contents/Resources/MarkEdit"
  cp Config/Info.plist "$app_path/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDevelopmentRegion en' "$app_path/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Dayday' "$app_path/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$app_path/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Dayday' "$app_path/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1.0' "$app_path/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1' "$app_path/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 14.0' "$app_path/Contents/Info.plist"
  iconset_path="$project_dir/.build/Dayday.iconset"
  mkdir -p "$iconset_path"
  cp Sources/DaydayApp/Assets.xcassets/AppIcon.appiconset/*.png "$iconset_path/"
  /usr/bin/iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/Dayday.icns"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string Dayday.icns' "$app_path/Contents/Info.plist"
else
# XcodeGen expands the app-source directory into individual project entries.
# SwiftPM sees a newly added file immediately, but a stale checked-in Xcode
# project does not. Regenerate only when the source graph changed so
# `run-local.sh` remains a reliable one-command development entry point.
project_file="$project_dir/Dayday.xcodeproj/project.pbxproj"
if [[ ! -f "$project_file" || "$project_dir/project.yml" -nt "$project_file" ]] \
  || [[ -n "$(find "$project_dir/Sources/DaydayApp" -type f -name '*.swift' -newer "$project_file" -print -quit)" ]]; then
  "$script_dir/generate-project"
fi

xcodebuild \
  -project Dayday.xcodeproj \
  -scheme Dayday \
  -configuration "$build_configuration" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_path" \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_identifier" \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_DEBUG_DYLIB=NO \
  build
fi

mkdir -p "$app_path/Contents/Resources/Licenses"
cp LICENSE "$app_path/Contents/Resources/Licenses/Dayday-MIT.txt"
cp ThirdParty/MarkEdit/LICENSE "$app_path/Contents/Resources/Licenses/MarkEdit-MIT.txt"
cp NOTICE "$app_path/Contents/Resources/Licenses/NOTICE.md"

if [[ "$build_configuration" == Release ]]; then
  /usr/bin/strip -S -x "$app_path/Contents/MacOS/Dayday"
fi

if [[ "$signing_mode" == adhoc ]]; then
  /usr/bin/codesign --force --deep --sign - \
    --identifier "$bundle_identifier" \
    --requirements "=designated => identifier \"$bundle_identifier\"" \
    --entitlements Config/Dayday.entitlements "$app_path"
else
# Linker-only ad-hoc signatures use the executable CDHash as their designated
# requirement. That hash changes after every rebuild, so macOS TCC sees a new
# application and re-prompts for Input Monitoring / Screen Recording. Sign with
# a stable local self-signed identity instead: its CDHash stays identical
# across rebuilds, so the granted permissions survive re-builds.
local_signing="$("$script_dir/make-local-code-signing-cert.sh")"
IFS=: read -r _cert_name identity keychain_path <<<"$local_signing"

# Use the dedicated development keychain explicitly. Do not call
# `security list-keychains -s`: that command replaces the user's search list
# and could remove unrelated identities configured by the user.
security unlock-keychain -p dayday "$keychain_path"

/usr/bin/codesign \
  --force \
  --deep \
  --keychain "$keychain_path" \
  --sign "$identity" \
  --identifier "$bundle_identifier" \
  --requirements "=designated => identifier \"$bundle_identifier\"" \
  --entitlements Config/Dayday.entitlements \
  "$app_path"
fi

if ! verification_output=$(/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path" 2>&1); then
  # The persistent development identity is intentionally self-signed. macOS
  # reports its untrusted chain even though the bundle was signed with the
  # expected local identity; retain every other verification failure.
  if [[ "$verification_output" != *"CSSMERR_TP_NOT_TRUSTED"* ]]; then
    print -u2 -- "$verification_output"
    exit 1
  fi
  print "Verified local self-signed development signature (untrusted chain expected)."
fi
print "$app_path"

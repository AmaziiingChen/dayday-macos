#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
environment_file="$project_dir/.env"

if [[ -f "$environment_file" ]]; then
  set -a
  source "$environment_file"
  set +a
fi

cd "$project_dir"
"$script_dir/build-local-app.sh"
derived_data_path=${DAYDAY_DERIVED_DATA_PATH:-"$project_dir/.build/xcode-derived-signed"}
app_path="$derived_data_path/Build/Products/Debug/Dayday.app"

if [[ ! -d "$app_path" ]]; then
  print -u2 "Dayday 本地开发构建未生成应用包：$app_path"
  exit 1
fi

# A normal `open` only activates an existing `app.dayday.local` process. That
# process may belong to another local worktree, which makes a rebuilt preview
# look as if it ignored the latest source. The local bundle identifier is
# deliberately distinct from the installed application, so stop the local
# development instance before launching this worktree's replacement.
local_development_pids() {
  # A stale preview can come from another Dayday worktree. Limit the fallback
  # to development bundles below a source checkout's .build directory; a separately
  # installed build is never matched or stopped.
  /bin/ps -axo pid=,command= | while read -r pid process_command; do
    case "$process_command" in
      */.build/*/Build/Products/Debug/Dayday.app/Contents/MacOS/Dayday)
        print "$pid"
        ;;
    esac
  done
}

is_local_development_app_running() {
  [[ -n "$(local_development_pids)" ]]
}

if is_local_development_app_running; then
  # A modal sheet can reject AppleScript termination. Continue to the bounded
  # wait and exact development-process fallback instead of abandoning the
  # freshly built preview under `set -e`.
  /usr/bin/osascript -e 'tell application id "app.dayday.local" to quit' || true
  for _ in {1..50}; do
    if ! is_local_development_app_running; then
      break
    fi
    sleep 0.1
  done
  if is_local_development_app_running; then
    # The application has already received a graceful termination request.
    # In development a stale instance otherwise keeps the old binary alive
    # indefinitely and makes every preview appear to ignore the latest build.
    # Target only the exact derived app after the bounded grace period.
    pids=("${(@f)$(local_development_pids)}")
    for pid in "${pids[@]}"; do
      /bin/kill -TERM "$pid" 2>/dev/null || true
    done
    for _ in {1..30}; do
      if ! is_local_development_app_running; then
        break
      fi
      sleep 0.1
    done
  fi
  if is_local_development_app_running; then
    print -u2 "Dayday 的本地开发实例未能退出；没有启动新的应用，以免并发写入本地数据。"
    exit 1
  fi
fi

# Launch through LaunchServices (open) instead of exec-ing the raw binary.
# TCC identifies the process by its bundle identity (app.dayday.local); exec-ing
# Contents/MacOS/Dayday starts a non-bundle client that macOS does not prompt for
# Input Monitoring / Screen Recording, whereas a bundle launch does.
open -n "$app_path"

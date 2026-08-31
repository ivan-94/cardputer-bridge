#!/usr/bin/env bash
set -euo pipefail

build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
app="${CARDPUTER_MACOS_APP:-$build_root/xcode/Build/Products/Debug/Cardputer Bridge.app}"
executable="$app/Contents/MacOS/Cardputer Bridge"
runtime_root="${CARDPUTER_BRIDGE_RUNTIME_ROOT:-$HOME/.local/share/cardputer-bridge/runtime}"
probe_path="${CARDPUTER_BRIDGE_MACOS_PROBE_PATH:-$runtime_root/macos-state.json}"
audio_probe_path="${CARDPUTER_BRIDGE_AUDIO_PROBE_PATH:-$runtime_root/audio-state.json}"
log_path="${CARDPUTER_BRIDGE_MACOS_LOG_PATH:-$runtime_root/macos-app.log}"
config_path="${CARDPUTER_BRIDGE_CONFIG_PATH:-}"
start_mic_live="${CARDPUTER_BRIDGE_START_MIC_LIVE:-}"
start_shortcut_learning="${CARDPUTER_BRIDGE_START_SHORTCUT_LEARNING:-}"

mkdir -p "$runtime_root"

if [[ ! -x "$executable" ]]; then
  printf 'BLOCKED CARDPUTER_MACOS_APP_NOT_BUILT app=%s\n' "$app" >&2
  exit 2
fi

product_pids() {
  {
    # Installed, version-suffixed and DerivedData copies share BLE, UDP and HAL
    # resources. Stop every Cardputer Bridge app before selecting one build.
    pgrep -f -x '.*/Cardputer Bridge[^/]*\.app/Contents/MacOS/Cardputer Bridge' || true
    pgrep -f -x '.*/Cardputer Bridge[^/]*\.app/Contents/MacOS/Cardputer Bridge .*' || true
  } | sort -u
}

launched_pids() {
  {
    pgrep -f -x "$executable" || true
    pgrep -f -x "$executable .*" || true
  } | sort -u
}

if [[ -n "$(product_pids)" ]]; then
  osascript -e 'tell application id "io.nexu.cardputerbridge.app" to quit' \
    >/dev/null 2>&1 || true
  for _ in {1..30}; do
    [[ -z "$(product_pids)" ]] && break
    sleep 0.1
  done
fi

while IFS= read -r pid; do
  [[ -n "$pid" ]] && kill -TERM "$pid"
done < <(product_pids)

for _ in {1..50}; do
  if [[ -z "$(product_pids)" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -n "$(product_pids)" ]]; then
  printf 'FAIL CARDPUTER_MACOS_APP_DID_NOT_STOP\n' >&2
  exit 1
fi

open_args=(
  -n -F
  --env "CARDPUTER_BRIDGE_BLUETOOTH_PROBE_PATH=$probe_path"
  --env "CARDPUTER_BRIDGE_AUDIO_PROBE_PATH=$audio_probe_path"
)
if [[ -n "$config_path" ]]; then
  open_args+=(--env "CARDPUTER_BRIDGE_CONFIG_PATH=$config_path")
fi
if [[ "$start_mic_live" == "1" ]]; then
  open_args+=(--env "CARDPUTER_BRIDGE_START_MIC_LIVE=1")
fi
if [[ "$start_shortcut_learning" == "1" ]]; then
  open_args+=(--env "CARDPUTER_BRIDGE_START_SHORTCUT_LEARNING=1")
fi
open "${open_args[@]}" \
  -o "$log_path" \
  --stderr "$log_path" \
  "$app" \
  --args -ApplePersistenceIgnoreState YES
for _ in {1..50}; do
  if [[ -n "$(launched_pids)" ]]; then
    # Do not accept a transient process that immediately hands activation to a
    # different installed copy with the same bundle identifier.
    sleep 1
    [[ -n "$(launched_pids)" ]] || continue
    printf 'PASS cardputer_macos_app_restarted app=%s probe=%s\n' \
      "$app" "$probe_path"
    exit 0
  fi
  sleep 0.1
done

printf 'FAIL CARDPUTER_MACOS_APP_DID_NOT_START app=%s\n' "$app" >&2
exit 1

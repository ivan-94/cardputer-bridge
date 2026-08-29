#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
bundle="$build_root/audio-plugin/CardputerBridgeAudio.driver"

if [[ "${CARDPUTER_BRIDGE_TEST_MODE:-0}" == 1 ]]; then
  current_uid="${CARDPUTER_BRIDGE_TEST_CURRENT_UID:?test current uid required}"
  coreaudio_uid="${CARDPUTER_BRIDGE_TEST_COREAUDIO_UID:?test Core Audio uid required}"
  ipc_contract="${CARDPUTER_BRIDGE_TEST_IPC_CONTRACT:?test IPC contract required}"
  peer_auth_contract="${CARDPUTER_BRIDGE_TEST_PEER_AUTH:?test peer auth required}"
else
  current_uid="$(id -u)"
  if ! coreaudio_uid="$(id -u _coreaudiod 2>/dev/null)"; then
    printf 'BLOCKED FF1_COREAUDIO_IDENTITY_UNKNOWN\n' >&2
    exit 2
  fi
  python3 "$project_dir/harness/verifier/audio_bundle.py" "$bundle" >/dev/null
  ipc_contract="$(plutil -extract CardputerBridgeAudioIPC raw "$bundle/Contents/Info.plist")"
  peer_auth_contract="$(plutil -extract CardputerBridgeAudioPeerAuth raw "$bundle/Contents/Info.plist")"
fi

if [[ "$ipc_contract" != "unix-scm-rights-v1"
      || "$peer_auth_contract" != "getpeereid-mutual-v1" ]]; then
  printf 'FAIL FF1_IPC_CONTRACT_UNSAFE ipc=%s peer_auth=%s\n' \
    "$ipc_contract" "$peer_auth_contract" >&2
  exit 1
fi

designed_cross_uid=false
if [[ "$current_uid" != "$coreaudio_uid" ]]; then designed_cross_uid=true; fi
printf 'PASS audio_ipc_contract_boundary app_uid=%s coreaudio_uid=%s designed_cross_uid=%s runtime_cross_uid=NOT_RUN ipc=%s peer_auth=%s\n' \
  "$current_uid" "$coreaudio_uid" "$designed_cross_uid" "$ipc_contract" "$peer_auth_contract"

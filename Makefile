.PHONY: verify-env verify-contracts verify-host build-firmware verify-firmware verify-firmware-release finalize-device-preflight finalize-device-flash verify-launcher-install build-macos verify-macos verify-macos-runtime verify-restart-mute-hil verify-device-mic-authority-hil verify-device-efficiency-hil verify-audio-latency-hil verify-system-microphone-ui-hil build-audio-plugin verify-audio-plugin verify-ff-0 verify-ff-1-preflight verify-ff-1 verify-ff-2-preflight verify-ff-2 verify-hil verify-hid-hil verify-hid-hil-preflight verify-phase-2 verify-phase-3 verify evidence-host evidence-ff-0 evidence-ff-1-preflight evidence-ff-1 evidence-ff-2-preflight evidence-ff-2

verify-env:
	./scripts/env-check.sh

verify-contracts:
	./scripts/verify-contracts.sh

verify-host:
	./scripts/verify-host.sh

build-firmware:
	./scripts/build-firmware.sh

verify-firmware:
	./scripts/verify-firmware.sh

verify-firmware-release:
	./scripts/finalize-device.sh --preflight

finalize-device-preflight:
	./scripts/finalize-device.sh --preflight

finalize-device-flash:
	./scripts/finalize-device.sh --flash-and-verify

verify-launcher-install:
	PYTHONPATH=. python3 -m unittest tests.contract.test_launcher_install

build-macos:
	./scripts/build-macos.sh

verify-macos:
	./scripts/verify-macos.sh

verify-macos-runtime:
	./scripts/verify-macos-bluetooth-runtime.sh

verify-restart-mute-hil:
	./scripts/verify_macos_restart_mute_hil.py

verify-device-mic-authority-hil:
	$(HOME)/.local/share/cardputer-bridge/launcher-venv/bin/python ./scripts/verify_device_mic_intent_authority_hil.py

verify-device-efficiency-hil:
	$(HOME)/.local/share/cardputer-bridge/launcher-venv/bin/python ./scripts/verify_device_efficiency_hil.py

verify-audio-latency-hil:
	$(HOME)/.local/share/cardputer-bridge/launcher-venv/bin/python ./scripts/verify_audio_latency_hil.py

verify-system-microphone-ui-hil:
	$(HOME)/.local/share/cardputer-bridge/launcher-venv/bin/python ./scripts/verify_macos_system_microphone_ui_hil.py

build-audio-plugin:
	./scripts/build-audio-plugin.sh

verify-audio-plugin:
	./scripts/verify-audio-plugin.sh

verify-ff-0: verify-contracts verify-host verify-firmware verify-macos verify-audio-plugin

verify-ff-1-preflight:
	./scripts/verify-ff-1-preflight.sh

verify-ff-1:
	./scripts/verify-ff-1.sh

verify-ff-2-preflight:
	./scripts/verify-ff-2-preflight.sh

verify-ff-2:
	./scripts/verify-ff-2.sh

verify-hil:
	./scripts/verify-hil.sh

verify-hid-hil:
	./scripts/verify-hid-hil.sh --case q
	./scripts/verify-hid-hil.sh --case g0-q

verify-hid-hil-preflight:
	./scripts/verify-hid-hil.sh --preflight

verify-phase-2:
	./scripts/verify-phase-2.sh

verify-phase-3:
	./scripts/verify-phase-3.sh

evidence-host:
	python3 harness/runners/run_suite.py host

evidence-ff-0:
	python3 harness/runners/run_suite.py ff0

evidence-ff-1-preflight:
	python3 harness/runners/run_suite.py ff1-preflight

evidence-ff-1:
	python3 harness/runners/run_suite.py ff1

evidence-ff-2-preflight:
	python3 harness/runners/run_suite.py ff2-preflight

evidence-ff-2:
	python3 harness/runners/run_suite.py ff2

verify: verify-ff-0 verify-hil

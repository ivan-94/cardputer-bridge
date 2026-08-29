# Cardputer Bridge BLE Protocol v1

This file is the standalone repository's executable BLE UUID contract. UUIDs are
identifiers, not an authentication boundary; characteristic access still depends
on BLE Secure Connections, bonding, and each characteristic's security policy.

| Name | UUID | Access |
| --- | --- | --- |
| Bridge Service | `15f98efe-c59c-46c4-be0f-29acfce5df6c` | Bonded-device discovery |
| Identity | `f80db63e-1321-440f-b69a-984ed11206f8` | Encrypted read |
| Command | `933966d7-0ad4-4412-aefe-ed53daae161f` | Authenticated write with response |
| State | `ec577f1b-0005-4855-b939-66ea4b4427e4` | Encrypted read and notify |

## Source Manifest

- `../../specs/Cardputer-Bridge-实现-Spec.md`, section “BLE GATT 协议” — canonical product specification when this repository is mounted at its AI Wiki submodule path.
- `firmware/components/ble_bridge/ble_bridge.c` — firmware byte-order representation checked by the contract test.
- `macos/Sources/CardputerBridgeCore/BLEProtocolV1.swift` — macOS representation checked by the same test.


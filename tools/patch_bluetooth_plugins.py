#!/usr/bin/env python3
"""Patch the two Bluetooth plugin dylibs so their default power alert is off.

This avoids touching the main Runner Mach-O (which must already be decrypted),
and avoids adding a launch dylib / LC_LOAD_DYLIB / framework signature.

Byte fingerprints are assertively checked before modification:

  flutter_blue_plus 1.32.12, +[FlutterBluePlusPlugin registerWithRegistrar:]:
    0x4270: 22 00 80 52   mov w2, #1   -> 02 00 80 52  mov w2, #0
    0x4274: 33 32 00 94   bl numberWithBool:
    The instance property becomes @NO before CBCentralManager is initialized.

  flutter_ble_peripheral 1.2.5, FlutterBlePeripheralManager.init:
    0x4588: 28 00 80 52   mov w8, #1   -> 08 00 80 52  mov w8, #0
    0x458c: a8 c2 00 39   strb w8, [x21, #0x30]
    This is the Bool true bridged into the CBPeripheralManager options dict.

Both targets are unencrypted (cryptid=0) Mach-O dylibs. No fixups are changed.
"""
from __future__ import annotations

from pathlib import Path
import sys

from macho import parse_macho

RULES = [
    {
        "path": "Payload/Runner.app/Frameworks/flutter_blue_plus.framework/flutter_blue_plus",
        "offset": 0x4270,
        "before": bytes.fromhex("2200805233320094"),
        "after": bytes.fromhex("0200805233320094"),
        "label": "CBCentralManagerOptionShowPowerAlertKey default",
    },
    {
        "path": "Payload/Runner.app/Frameworks/flutter_ble_peripheral.framework/flutter_ble_peripheral",
        "offset": 0x4588,
        "before": bytes.fromhex("28008052a8c20039"),
        "after": bytes.fromhex("08008052a8c20039"),
        "label": "CBPeripheralManagerOptionShowPowerAlertKey",
    },
]


def patch(root: Path, rule: dict) -> None:
    path = root / rule["path"]
    data = bytearray(path.read_bytes())
    info = parse_macho(data, str(path))
    for enc in info.encryption:
        if enc.cryptid != 0:
            raise ValueError(f"{path}: framework is FairPlay encrypted; refusing to patch")
    off = rule["offset"]
    before = rule["before"]
    after = rule["after"]
    current = bytes(data[off:off + len(before)])
    if current == after:
        print(f"{rule['label']}: already patched")
        return
    if current != before:
        raise ValueError(
            f"{path}: unexpected bytes at 0x{off:x}: {current.hex(' ')}; "
            f"expected {before.hex(' ')}. Refusing to patch a different build.")
    data[off:off + len(before)] = after
    path.write_bytes(data)
    print(f"{rule['label']}: patched at 0x{off:x}")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} unpacked-app-root-or-Payload-root", file=sys.stderr)
        return 2
    root = Path(argv[1])
    # Normalize accepted roots: build root, Payload dir, or Runner.app itself.
    if root.name == "Runner.app" and (root / "Frameworks").is_dir():
        offset = ""
        path_root = root.parent.parent  # Payload's parent: build root
        prefix = "Payload/Runner.app/"
    elif (root / "Payload" / "Runner.app" / "Frameworks").is_dir():
        offset = "Payload/"
        path_root = root
    elif (root / "Runner.app" / "Frameworks").is_dir():
        offset = ""
        path_root = root / "Payload"
    else:
        raise ValueError(
            f"{root}: expected Runner.app/Frameworks or Payload/Runner.app/Frameworks")
    for rule in RULES:
        resolved = dict(rule)
        resolved["path"] = offset + rule["path"].removeprefix("Payload/")
        if root.name == "Runner.app":
            # path_root here is the build root; keep the full relative path.
            resolved["path"] = rule["path"]
            patch(path_root, resolved)
        else:
            patch(root, resolved)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

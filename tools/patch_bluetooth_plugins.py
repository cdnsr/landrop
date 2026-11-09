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
    # Accept either the Runner.app directory or its parent Payload directory.
    if (root / "Payload" / "Runner.app" / "Frameworks").is_dir():
        root = root / "Payload"
    elif (root / "Runner.app" / "Frameworks").is_dir():
        # Also accept a root whose Payload directory was omitted by the caller.
        for rule in RULES:
            rule = dict(rule)
            rule["path"] = rule["path"].removeprefix("Payload/")
            patch(root, rule)
        return 0
    for rule in RULES:
        patch(root, rule)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

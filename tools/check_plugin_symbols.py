#!/usr/bin/env python3
"""Verify the rebuilt flutter_sharing_intent framework is a drop-in replacement.

Runner links against the plugin by mangled symbol, so the replacement must export
exactly the symbols the original binary exported. Anything missing is a launch
crash, not a subtle bug, so this check runs before packaging.

Usage:
  python3 tools/check_plugin_symbols.py path/to/flutter_sharing_intent
"""
from __future__ import annotations

from pathlib import Path
import struct
import sys

# Symbols Runner and GeneratedPluginRegistrant resolve at load time.
REQUIRED_EXPORTS = [
    "_OBJC_CLASS_$_FlutterSharingIntentPlugin",
    "_OBJC_METACLASS_$_FlutterSharingIntentPlugin",
    "_$s22flutter_sharing_intent31SwiftFlutterSharingIntentPluginC8instanceACvau",
    "_$s22flutter_sharing_intent31SwiftFlutterSharingIntentPluginC8instanceACvgZ",
    "_$s22flutter_sharing_intent31SwiftFlutterSharingIntentPluginC8register4withySo0eH9Registrar_p_tFZ",
    "_$s22flutter_sharing_intent31SwiftFlutterSharingIntentPluginC6handle_6resultySo0E10MethodCallC_yypSgctF",
    "_$s22flutter_sharing_intent31SwiftFlutterSharingIntentPluginC8onListen13withArguments9eventSinkSo0E5ErrorCSgypSg_yAJctF",
    "_$s22flutter_sharing_intent31SwiftFlutterSharingIntentPluginC8onCancel13withArgumentsSo0E5ErrorCSgypSg_tF",
]

# The replacement must keep the plugin's framework identity.
EXPECTED_INSTALL_NAME = "@rpath/flutter_sharing_intent.framework/flutter_sharing_intent"


def symbols(data: bytes) -> tuple[set[str], set[str]]:
    """Return (exported, undefined) symbol names from the LC_SYMTAB table."""
    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    symtab = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == 0x2:
            symtab = struct.unpack_from("<IIII", data, offset + 8)
        offset += size
    if symtab is None:
        raise ValueError("no LC_SYMTAB")

    symoff, nsyms, stroff, _ = symtab
    exported: set[str] = set()
    undefined: set[str] = set()
    for i in range(nsyms):
        strx, ntype = struct.unpack_from("<IB", data, symoff + i * 16)
        name = data[stroff + strx:].split(b"\0")[0].decode("utf-8", "replace")
        if not name:
            continue
        # N_TYPE: 0x0e = N_SECT (defined), 0x0 = N_UNDF, 0x1 = N_EXT|N_UNDF
        if ntype & 0x0e:
            exported.add(name)
        else:
            undefined.add(name)
    return exported, undefined


def install_name(data: bytes) -> str:
    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == 0xD:  # LC_ID_DYLIB
            nameoff = struct.unpack_from("<I", data, offset + 8)[0]
            return data[offset + nameoff:offset + size].split(b"\0")[0].decode()
        offset += size
    return ""


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} flutter_sharing_intent", file=sys.stderr)
        return 2
    path = Path(argv[1])
    if not path.is_file():
        print(f"missing plugin binary: {path}", file=sys.stderr)
        return 1

    data = path.read_bytes()
    exported, undefined = symbols(data)
    errors: list[str] = []

    for symbol in REQUIRED_EXPORTS:
        if symbol not in exported:
            errors.append(f"missing export: {symbol}")

    name = install_name(data)
    if name != EXPECTED_INSTALL_NAME:
        errors.append(f"unexpected install name: {name!r}")

    # The plugin must not depend on itself under the original framework path,
    # which would happen if the module were built as an executable.
    for symbol in undefined:
        if "flutter_sharing_intent" in symbol and "Flutter" not in symbol:
            errors.append(f"unexpected external dependency: {symbol}")

    if errors:
        print("Plugin symbol check FAILED:", file=sys.stderr)
        for error in errors:
            print(" -", error, file=sys.stderr)
        return 1
    print(f"plugin exports all {len(REQUIRED_EXPORTS)} required symbols")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

#!/usr/bin/env python3
"""Verify the replacement Share Extension NIB class name encoding.

The original MainInterface.storyboardc NIB is a NIBArchive. Its
UIClassSwapper stores a length-prefixed string object for the Swift class
`_TtC15Share_Extension19ShareViewController` (42 bytes, prefix byte 0xAA).
The replacement executable defines an Objective-C class with that exact
runtime name, so the NIB must NOT be modified at all. A former approach
padded the 42-byte string with NULs and broke NSClassFromString.

This tool simply asserts that the original encoded class name is present and
that the new executable (when supplied) contains the same runtime class name.
"""
from __future__ import annotations

from pathlib import Path
import sys

OLD = b"_TtC15Share_Extension19ShareViewController"
LENGTH_PREFIX = 0x80 | len(OLD)


def check_nib(path: Path) -> None:
    data = path.read_bytes()
    if data[:10] != b"NIBArchive":
        raise ValueError(f"{path}: not a NIBArchive")
    pos = data.find(OLD)
    if pos <= 0 or data[pos - 1] != LENGTH_PREFIX:
        raise ValueError(
            f"{path}: expected 0x{LENGTH_PREFIX:02x} length prefix for "
            f"{len(OLD)}-byte Swift class name; NIB is not the expected 2.8.2 build")
    if b"LANDropShareViewController" in data:
        raise ValueError(f"{path}: NIB was rewritten; use the original NIB unchanged")
    print(f"{path}: original {len(OLD)}-byte class name preserved")


def check_binary(path: Path) -> None:
    data = path.read_bytes()
    if OLD not in data:
        raise ValueError(f"{path}: replacement executable lacks runtime class name {OLD!r}")
    print(f"{path}: ObjC runtime class {OLD.decode()} present")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} MainInterface.nib [replacement-executable]", file=sys.stderr)
        return 2
    check_nib(Path(argv[1]))
    if len(argv) > 2:
        check_binary(Path(argv[2]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

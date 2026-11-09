#!/usr/bin/env python3
"""Generate XML entitlements plists with literal Team IDs for TrollStore.

TrollStore preserves entitlements from each Mach-O's LC_CODE_SIGNATURE and
creates App Group containers from `com.apple.security.application-groups`.
A completely unsigned IPA would lose the App Group for both Runner and the
Share Extension. This script writes two standalone plists with literal values
(no shell interpolation, no Xcode $(AppIdentifierPrefix) build setting).
"""
from __future__ import annotations

import plistlib
from pathlib import Path
import sys

REQUIRED_KEYS = (
    "application-identifier",
    "com.apple.developer.team-identifier",
    "com.apple.security.application-groups",
)

# Values are intentionally literal. Do not use Xcode build-setting variables.
APP_ENTITLEMENTS = {
    "application-identifier": "JAQBXTUN25.app.landrop.landrop-flutter",
    "com.apple.developer.team-identifier": "JAQBXTUN25",
    "com.apple.developer.device-information.user-assigned-device-name": True,
    "com.apple.developer.networking.multicast": True,
    "com.apple.security.application-groups": [
        "group.app.landrop.landrop-flutter",
    ],
}
SHARE_ENTITLEMENTS = {
    "application-identifier": "JAQBXTUN25.app.landrop.landrop-flutter.Share-Extension",
    "com.apple.developer.team-identifier": "JAQBXTUN25",
    "com.apple.security.application-groups": [
        "group.app.landrop.landrop-flutter",
    ],
}


def write(path: Path, values: dict) -> None:
    for key in REQUIRED_KEYS:
        if key not in values:
            raise ValueError(f"{path}: missing {key}")
    for value in values.values():
        if isinstance(value, str) and "$(" in value:
            raise ValueError(f"{path}: unexpanded build setting {value!r}")
    path.write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_XML, sort_keys=True))
    print(f"wrote {path}")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} app.entitlements share.entitlements", file=sys.stderr)
        return 2
    write(Path(argv[1]), APP_ENTITLEMENTS)
    write(Path(argv[2]), SHARE_ENTITLEMENTS)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

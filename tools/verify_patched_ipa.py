#!/usr/bin/env python3
"""Verify the built TrollStore IPA structure, patches and entitlements.

No Xcode is required; only zipfile/plistlib and the local Mach-O parser.
"""
from __future__ import annotations

from pathlib import Path
import plistlib
import sys
import zipfile

from macho import (LC_CODE_SIGNATURE, LC_LOAD_DYLIB, PLATFORM_IOS,
                   decode_version, entropy, is_macho, iter_slices,
                   parse_macho)

APP = "Payload/Runner.app"
SHARE = APP + "/PlugIns/Share Extension.appex"
NIB = SHARE + "/Base.lproj/MainInterface.storyboardc/UIViewController-j1y-V4-xli.nib"
FBP = APP + "/Frameworks/flutter_blue_plus.framework/flutter_blue_plus"
FBLE = APP + "/Frameworks/flutter_ble_peripheral.framework/flutter_ble_peripheral"
EXPECTED_GROUP = "group.app.landrop.landrop-flutter"
NIB_CLASS = b"_TtC15Share_Extension19ShareViewController"


def entitlements(binary: bytes) -> dict:
    """Extract XML entitlements directly from the embedded superblob."""
    sl = iter_slices(binary, "entitlements")[0]
    ncmds = sl.u32(16)
    off = 32
    for _ in range(ncmds):
        cmd, size = __import__("struct").unpack_from("<II", sl.data, sl.base + off)
        if cmd == LC_CODE_SIGNATURE:
            sigoff, sigsize = __import__("struct").unpack_from(
                "<II", sl.data, sl.base + off + 8)
            blob = sl.raw(sigoff, sigsize)
            # CS Superblob: big-endian magic/length/count, then big-endian
            # index entries (type, offset) starting at byte 12.
            magic, length, count = __import__("struct").unpack_from(">III", blob, 0)
            if magic != 0xFADE0CC0:
                raise ValueError("bad code signature superblob")
            for i in range(count):
                typ, entry_off = __import__("struct").unpack_from(
                    ">II", blob, 12 + 8 * i)
                if typ == 5 and entry_off + 8 <= len(blob):
                    magic2, blen = __import__("struct").unpack_from(
                        ">II", blob, entry_off)
                    if magic2 == 0xFADE7171:
                        return plistlib.loads(blob[entry_off + 8:entry_off + blen])
        off += size
    raise ValueError("no XML entitlements slot found")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} output.ipa", file=sys.stderr)
        return 2
    path = Path(argv[1])
    errors: list[str] = []
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())
        get = lambda n: z.read(n)

        for required in [APP + "/Info.plist", APP + "/Runner", SHARE + "/Info.plist",
                         SHARE + "/Share Extension", NIB, FBP, FBLE]:
            if required not in names:
                errors.append(f"missing IPA entry: {required}")

        for forbidden_prefix in ("SC_Info/", "Payload/Runner.app/SC_Info/",
                                 SHARE + "/SC_Info/"):
            if any(n.startswith(forbidden_prefix) for n in names):
                errors.append(f"DRM metadata remains: {forbidden_prefix}")

        app_info = plistlib.loads(get(APP + "/Info.plist"))
        for key in ("ITSDRMScheme", "UISupportedDevices"):
            if key in app_info:
                errors.append(f"{key} remains in app Info.plist")
        if app_info.get("CFBundleIdentifier") != "app.landrop.landrop-flutter":
            errors.append("app bundle ID changed; URL scheme/App Group would break")
        scheme = app_info.get("CFBundleURLTypes", [{}])[0].get("CFBundleURLSchemes", [None])[0]
        if scheme != "SharingMedia-app.landrop.landrop-flutter":
            errors.append(f"unexpected sharing URL scheme: {scheme}")
        if app_info.get("AppGroupId") != EXPECTED_GROUP:
            errors.append("app Info.plist AppGroupId missing/wrong")
        share_info = plistlib.loads(get(SHARE + "/Info.plist"))
        if share_info.get("AppGroupId") != EXPECTED_GROUP:
            errors.append("Share Extension Info.plist AppGroupId missing/wrong")

        # NIB must be the untouched original; the replacement executable defines
        # a class whose runtime name is exactly the original Swift mangle.
        nib = get(NIB)
        pos = nib.find(NIB_CLASS)
        if pos <= 0 or nib[pos - 1] != (0x80 | len(NIB_CLASS)):
            errors.append("NIB class-name length prefix is wrong or NIB was rewritten")
        share_bin = get(SHARE + "/Share Extension")
        if NIB_CLASS not in share_bin:
            errors.append("replacement Share Extension lacks the NIB controller class")

        # Two 4-byte Bluetooth instruction patches.
        checks = [
            (FBP, 0x4270, bytes.fromhex("02008052")),
            (FBLE, 0x4588, bytes.fromhex("08008052")),
        ]
        for name, off, expected in checks:
            data = get(name)
            if data[off:off + 4] != expected:
                errors.append(f"{name}: Bluetooth patch missing at 0x{off:x}")

        # Every Mach-O must be ad-hoc signed (TrollStore preserves entitlements),
        # decrypted, iOS/arm64, and must not contain the obsolete launch dylib.
        macho_count = 0
        for name in sorted(names):
            data = get(name)
            if not is_macho(data):
                continue
            macho_count += 1
            try:
                mi = parse_macho(data, name)
            except ValueError as exc:
                errors.append(str(exc))
                continue
            for enc in mi.encryption:
                if enc.cryptid != 0:
                    errors.append(f"{name}: cryptid={enc.cryptid} (TrollStore 180/184)")
                if enc.cryptsize and enc.entropy > 7.8:
                    errors.append(f"{name}: crypt page entropy={enc.entropy:.2f}")
            if not mi.code_signature:
                errors.append(f"{name}: missing LC_CODE_SIGNATURE / ad-hoc signature")
            if any("LANDropPatches" in d for d in mi.dylibs):
                errors.append(f"{name}: obsolete LANDropPatches load command")
            for platform, minos, sdk in mi.build_versions:
                if platform != PLATFORM_IOS:
                    errors.append(f"{name}: non-iOS platform {platform}")
            if mi.entryoff and name == APP + "/Runner":
                off = mi.entryoff[0]
                # High-entropy entry page is a strong signal of a fake decrypt.
                if entropy(data[off & ~0xfff:(off & ~0xfff) + 0x1000]) > 7.8:
                    errors.append(f"{name}: LC_MAIN page looks encrypted")

        runner_ent = entitlements(get(APP + "/Runner"))
        share_ent = entitlements(get(SHARE + "/Share Extension"))
        for label, ent in (("Runner", runner_ent), ("Share", share_ent)):
            groups = ent.get("com.apple.security.application-groups", [])
            if EXPECTED_GROUP not in groups:
                errors.append(f"{label}: App Group entitlement missing/wrong: {groups}")
            if "application-identifier" not in ent:
                errors.append(f"{label}: application-identifier missing")
            if "com.apple.developer.team-identifier" not in ent:
                errors.append(f"{label}: team-identifier missing")
            for v in ent.values():
                if isinstance(v, str) and "$(" in v:
                    errors.append(f"{label}: unexpanded build setting in entitlements")
        if not runner_ent.get("com.apple.developer.networking.multicast"):
            errors.append("Runner lost multicast entitlement")
        if not runner_ent.get("com.apple.developer.device-information.user-assigned-device-name"):
            errors.append("Runner lost user-assigned-device-name entitlement")
        print(f"checked {macho_count} Mach-O files")
        print(f"Runner entitlements: {sorted(runner_ent)}")
        print(f"Share entitlements: {sorted(share_ent)}")

    if errors:
        print("IPA verification FAILED:", file=sys.stderr)
        for e in errors:
            print(" -", e, file=sys.stderr)
        return 1
    print("IPA verification passed (TrollStore structural checks only)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

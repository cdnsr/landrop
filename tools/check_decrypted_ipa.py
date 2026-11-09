#!/usr/bin/env python3
"""Validate that the input IPA is genuinely decrypted and TrollStore-ready.

TrollStore 2.x rejects an encrypted main binary with error 180, and warns
about encrypted nested binaries with error 184. Merely setting cryptid to 0
is not sufficient: the formerly encrypted pages must contain ARM64 plaintext
and differ from the encrypted App Store IPA. This checker verifies structure,
entropy and, when the original encrypted IPA is supplied, byte differences.

The build replaces the Share Extension executable, so its original encrypted
page may still be present in the *input* IPA; only Runner and every other
Mach-O that will be kept must be decrypted. Supply --allow-encrypted-share for
that case. The output verifier (verify_patched_ipa.py) then requires all
Mach-O files, including the replacement appex, to be unencrypted.

Usage:
  python3 tools/check_decrypted_ipa.py INPUT.ipa [ORIGINAL_ENCRYPTED.ipa]
                                      [--allow-encrypted-share]

INPUT may be an IPA or an unpacked .app directory.
"""
from __future__ import annotations

from pathlib import Path
import plistlib
import sys
import zipfile

from macho import (CPU_TYPE_ARM64, PLATFORM_IOS, decode_version,
                   entropy, is_macho, looks_like_arm64_code, parse_macho)

EXPECTED_CRYPT_PAGES = {
    "Payload/Runner.app/Runner": (0x5000, 0x1000),
    "Payload/Runner.app/PlugIns/Share Extension.appex/Share Extension": (0xC000, 0x1000),
}
SHARE_EXE = "Payload/Runner.app/PlugIns/Share Extension.appex/Share Extension"


def read_ipa(path: Path) -> dict[str, bytes]:
    with zipfile.ZipFile(path) as z:
        return {n: z.read(n) for n in z.namelist() if not n.endswith("/")}


def read_app(path: Path) -> dict[str, bytes]:
    root = path.parent.parent
    return {p.relative_to(root).as_posix(): p.read_bytes()
            for p in path.rglob("*") if p.is_file()}


def load(path: Path) -> dict[str, bytes]:
    return read_app(path) if path.is_dir() else read_ipa(path)


def main(argv: list[str]) -> int:
    allow_encrypted_share = "--allow-encrypted-share" in argv
    argv = [a for a in argv if a != "--allow-encrypted-share"]
    if len(argv) < 2:
        print(f"usage: {argv[0]} input.ipa|.app [original-encrypted.ipa] "
              "[--allow-encrypted-share]", file=sys.stderr)
        return 2
    source = Path(argv[1])
    original = Path(argv[2]) if len(argv) > 2 else None
    files = load(source)
    errors: list[str] = []

    app_infos = [n for n in files if n.startswith("Payload/") and
                 n.count("/") == 2 and n.endswith(".app/Info.plist")]
    if len(app_infos) != 1:
        print("Decryption check FAILED:", file=sys.stderr)
        print(f" - expected one Payload/*.app/Info.plist, found {len(app_infos)}",
              file=sys.stderr)
        return 1
    app = app_infos[0].rsplit("/", 1)[0]
    info = plistlib.loads(files[app_infos[0]])
    exe = info.get("CFBundleExecutable")
    main_exe = f"{app}/{exe}" if exe else ""
    if main_exe not in files:
        errors.append(f"main executable missing: {main_exe}")

    machos: dict[str, object] = {}
    encrypted: list[str] = []
    for name, data in sorted(files.items()):
        if not is_macho(data):
            continue
        try:
            mi = parse_macho(data, name)
        except ValueError as exc:
            errors.append(str(exc))
            continue
        machos[name] = mi
        is_share = name == SHARE_EXE
        for enc in mi.encryption:
            if enc.cryptid != 0:
                if is_share and allow_encrypted_share:
                    print(f"NOTE: {name} remains encrypted; build will replace it")
                    continue
                encrypted.append(f"{name}: cryptid={enc.cryptid}")
                continue
            if enc.cryptsize and enc.entropy > 7.8:
                errors.append(
                    f"{name}: cryptid=0 but crypt page entropy={enc.entropy:.2f} "
                    "(looks like FairPlay ciphertext, not a real decrypted dump)")
            if (enc.cryptsize and name in EXPECTED_CRYPT_PAGES and
                    not looks_like_arm64_code(enc.raw)):
                errors.append(
                    f"{name}: cryptid=0 but crypt page does not look like ARM64 code "
                    "(zero-filled or otherwise invalid decrypted dump)")
        for platform, minos, sdk in mi.build_versions:
            if platform != PLATFORM_IOS:
                errors.append(f"{name}: unexpected platform {platform}")
            print(f"{name}: iOS {decode_version(minos)} (SDK {decode_version(sdk)})")
        for sl in mi.slices:
            if sl.cputype != CPU_TYPE_ARM64:
                errors.append(f"{name}: unexpected CPU type 0x{sl.cputype:x}")

    if encrypted:
        errors.append("encrypted Mach-O files remain: " + ", ".join(encrypted))

    if original:
        orig = read_ipa(original)
        for name, (off, size) in EXPECTED_CRYPT_PAGES.items():
            if name not in orig or name not in files:
                errors.append(f"comparison missing binary: {name}")
                continue
            if name == SHARE_EXE and allow_encrypted_share:
                continue
            old_page = orig[name][off:off + size]
            if entropy(old_page) < 7.5:
                errors.append(f"original encrypted page is not high entropy: {name}")
            new_page = files[name][off:off + size]
            if new_page == old_page:
                errors.append(f"{name}: encrypted 0x{off:x} page was NOT replaced with plaintext")
            else:
                if entropy(new_page) > 7.8:
                    errors.append(f"{name}: replacement 0x{off:x} page still looks encrypted")
                if not looks_like_arm64_code(new_page):
                    errors.append(
                        f"{name}: replacement 0x{off:x} page does not look like ARM64 code")
                print(f"{name}: 0x{off:x} plaintext differs; entropy "
                      f"{entropy(old_page):.2f} -> {entropy(new_page):.2f}")
    elif not allow_encrypted_share:
        print("WARNING: supply the original encrypted IPA to verify plaintext pages; "
              "a cryptid-only fake decrypt cannot be detected reliably", file=sys.stderr)

    if any("SC_Info/" in n for n in files):
        print("WARNING: SC_Info remains; decrypted TrollStore IPAs normally remove it",
              file=sys.stderr)
    p = plistlib.loads(files[app_infos[0]])
    for key in ("ITSDRMScheme", "UISupportedDevices"):
        if key in p:
            print(f"NOTE: {key} remains in Info.plist (build script removes it)")

    if errors:
        print("Decryption check FAILED:", file=sys.stderr)
        for error in errors:
            print(" -", error, file=sys.stderr)
        return 1
    print("Decryption check passed: no unintended cryptid=1 or high-entropy crypt pages")
    if original:
        print("Confirmed: original FairPlay pages were replaced with plaintext bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

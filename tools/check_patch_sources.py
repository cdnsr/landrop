#!/usr/bin/env python3
"""Static checks for the TrollStore-oriented LANDrop iOS patch sources.

Runs on Windows, Linux and macOS without Xcode. It does not require the
decrypted input IPA (which must be supplied by the user on the Actions run).
"""
from __future__ import annotations

from pathlib import Path
import plistlib
import sys

ROOT = Path(__file__).resolve().parent.parent
errors: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def text(rel: str) -> str:
    path = ROOT / rel
    require(path.is_file(), f"missing file: {rel}")
    return path.read_text(encoding="utf-8") if path.is_file() else ""


required = [
    "ANALYSIS.md",
    "README.md",
    ".github/workflows/build-ios.yml",
    "scripts/build_patched_ipa.sh",
    "patches/ios/Share Extension/ShareViewController.m",
    "patches/ios/Share Extension/main.m",
    "patches/ios/Share Extension/ShareExtension.h",
    "tools/macho.py",
    "tools/check_decrypted_ipa.py",
    "tools/patch_bluetooth_plugins.py",
    "tools/check_share_nib.py",
    "tools/prepare_entitlements.py",
    "tools/verify_patched_ipa.py",
]
for rel in required:
    text(rel)

bt = text("tools/patch_bluetooth_plugins.py")
for token in ["flutter_blue_plus", "flutter_ble_peripheral",
              "02008052", "08008052", "cryptid != 0"]:
    require(token in bt, f"Bluetooth patch tool missing: {token}")

share = text("patches/ios/Share Extension/ShareViewController.m")
for token in [
    "_TtC15Share_Extension19ShareViewController",
    "loadFileRepresentationForTypeIdentifier",
    "loadDataRepresentationForTypeIdentifier",
    "loadItemForTypeIdentifier",
    "SharingKey", "kSchemePrefix", "SharingFileTypeImage",
    "writeSharedObject", "Library/Preferences", "AppGroupId",
    "LANDropIsArchivedPlist", "LANDropRepairArchivedPNGAtURL",
    "NSKeyedUnarchiver", "bplist00",
    "dispatch_group_enter", "completeRequestReturningItems",
    "NSFileCoordinator",
]:
    require(token in share, f"Share extension missing: {token}")
# The known-good load/copy path must stay intact: no storeImageURL wrapper,
# no canLoadObjectOfClass, no ImageIO gate before the file is copied.
for forbidden in ["storeImageURL", "canLoadObjectOfClass",
                  "CGImageSourceCreateWithData", "LANDropRepairScreenshotData"]:
    require(forbidden not in share,
            f"Share extension must not contain regression-prone helper: {forbidden}")
require(share.count("{") == share.count("}"), "Share extension has unbalanced braces")

nib = text("tools/check_share_nib.py")
require("NIBArchive" in nib, "NIB checker missing NIBArchive validation")
require("_TtC15Share_Extension19ShareViewController" in nib,
        "NIB checker missing original class name")
require("must NOT be modified" in nib, "NIB checker missing no-rewrite rule")

check = text("tools/check_decrypted_ipa.py")
for token in ["cryptid", "entropy", "original-encrypted.ipa", "SC_Info",
              "--allow-encrypted-share"]:
    require(token in check, f"Decryption checker missing: {token}")

prepare = text("tools/prepare_entitlements.py")
for token in ["application-identifier", "com.apple.security.application-groups",
              "JAQBXTUN25", "$("]:
    require(token in prepare, f"Entitlements generator missing: {token}")

script = text("scripts/build_patched_ipa.sh")
for token in [
    "check_decrypted_ipa.py", "patch_bluetooth_plugins.py",
    "check_share_nib.py", "prepare_entitlements.py",
    "ShareViewController.m", "main.m", "-Wl,-e,_NSExtensionMain",
    "--allow-encrypted-share", "AppGroupId", "--entitlements", "ITSDRMScheme", "UISupportedDevices", "SC_Info",
    "cryptid", "-fixed-trollstore.ipa",
]:
    require(token in script, f"Build script missing: {token}")
require("insert_load_dylib.py" not in script, "obsolete LC_LOAD_DYLIB injection remains")
script_lines = [line for line in script.splitlines()
                if not line.lstrip().startswith("#")]
require(not any("MinimumOSVersion" in line for line in script_lines),
        "build script must not change MinimumOSVersion")
require("LANDropPatches" not in script, "obsolete launch framework remains")

workflow = text(".github/workflows/build-ios.yml")
for token in [
    "workflow_dispatch", "cache", "ipa_asset", "github.ref_type",
    "releases", "draft == true", "application/octet-stream",
    "actions/upload-artifact@v4", "check_patch_sources.py",
    "verify_patched_ipa.py", "macos-latest", "compression-level: 0",
]:
    require(token in workflow, f"Workflow missing: {token}")
require("decrypted_ipa_url" not in workflow,
        "workflow must read the IPA from the selected tag's draft Release")

analysis = text("ANALYSIS.md")
readme = text("README.md")
for token in ["TrollStore", "180", "cryptid", "SC_Info"]:
    require(token in analysis and token in readme,
            f"Documentation missing TrollStore/decryption detail: {token}")
require("github_token" not in readme and "D:\\GitProject" not in readme,
        "README must not include local paths or credential filenames")

for rel in [".github/workflows/build-ios.yml"]:
    try:
        import yaml  # type: ignore
        yaml.safe_load((ROOT / rel).read_text())
    except ImportError:
        pass
    except Exception as exc:
        errors.append(f"workflow YAML parse error: {exc}")

if errors:
    print("Static checks FAILED:", file=sys.stderr)
    for error in errors:
        print(f" - {error}", file=sys.stderr)
    sys.exit(1)
print("Static checks passed")

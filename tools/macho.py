#!/usr/bin/env python3
"""Shared, auditable Mach-O helpers for LANDrop iOS patch validation.

Apple's loader.h constants are used here; in particular LC_ENCRYPTION_INFO is
0x21 and LC_ENCRYPTION_INFO_64 is 0x2C (0x2D is LC_LINKER_OPTION).
"""
from __future__ import annotations

from dataclasses import dataclass
import collections
import hashlib
import math
import struct
import zipfile
from pathlib import Path

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM = 0xCEFAEDFE
MH_CIGAM_64 = 0xCFFAEDFE

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0xC
LC_CODE_SIGNATURE = 0x1D
LC_SEGMENT = 0x1
LC_ENCRYPTION_INFO = 0x21
LC_ENCRYPTION_INFO_64 = 0x2C
LC_DYLD_INFO_ONLY = 0x80000022
LC_MAIN = 0x80000028
LC_BUILD_VERSION = 0x32
LC_RPATH = 0x8000001C

PLATFORM_IOS = 2
CPU_TYPE_ARM64 = 0x0100000C


@dataclass
class Slice:
    base: int
    size: int
    data: bytes | bytearray
    label: str
    cputype: int = 0
    cpusubtype: int = 0

    def u32(self, offset: int) -> int:
        return struct.unpack_from("<I", self.data, self.base + offset)[0]

    def raw(self, offset: int, size: int) -> bytes:
        return bytes(self.data[self.base + offset:self.base + offset + size])


@dataclass
class Encryption:
    command_offset: int
    cryptoff: int
    cryptsize: int
    cryptid: int
    is_64: bool

    @property
    def page(self) -> bytes:
        """The crypt range bytes for an encrypted slice; empty when cryptid=0."""
        return self.raw

    raw: bytes = b""

    @property
    def entropy(self) -> float:
        return entropy(self.raw)

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.raw).hexdigest()


@dataclass
class MachOInfo:
    label: str
    slices: list[Slice]
    encryption: list[Encryption]
    entryoff: list[int]
    build_versions: list[tuple[int, int, int]]
    code_signature: list[tuple[int, int]]
    dylibs: list[str]
    rpaths: list[str]
    first_section: int
    linkedit: list[tuple[int, int, int, int, int]]
    symtab: list[tuple[int, int, int, int, int]]
    sizeofcmds: int
    ncmds: int


def looks_like_arm64_code(data: bytes) -> bool:
    """Heuristic check that a decrypted __TEXT page contains code, not zeros.

    A zero-filled page has low entropy and would otherwise pass an entropy-only
    check. Real ARM64 pages have many nonzero 32-bit words and common prologue
    / control-flow instructions. No single byte pattern is required here
    because different decrypt tools write back different amounts of padding.
    """
    if len(data) < 64:
        return False
    words = struct.unpack_from("<%dI" % (len(data) // 4), data, 0)
    nonzero = sum(1 for w in words if w != 0)
    common = sum(1 for w in words if (w & 0xFF000000) in (0xA9000000, 0xD1000000,
                                                          0x91000000, 0x94000000,
                                                          0xD6000000, 0xA8000000))
    return nonzero >= len(words) // 2 and common >= 8


def entropy(data: bytes) -> float:
    if not data:
        return 0.0
    counts = collections.Counter(data)
    return -sum((n / len(data)) * math.log2(n / len(data)) for n in counts.values())


def is_macho(data: bytes) -> bool:
    if len(data) < 4:
        return False
    magic = struct.unpack_from(">I", data, 0)[0]
    return magic in (FAT_MAGIC, FAT_MAGIC_64, MH_MAGIC, MH_MAGIC_64,
                     MH_CIGAM, MH_CIGAM_64)


def iter_slices(data: bytes | bytearray, label: str = "") -> list[Slice]:
    if len(data) < 32:
        return []
    magic = struct.unpack_from(">I", data, 0)[0]
    out: list[Slice] = []
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack_from(">I", data, 4)[0]
        arch_size = 32 if magic == FAT_MAGIC_64 else 20
        for i in range(nfat):
            off = 8 + i * arch_size
            if magic == FAT_MAGIC_64:
                cputype, cpusub, base, size, align = struct.unpack_from(">iiQQI", data, off)
            else:
                cputype, cpusub, base, size, align = struct.unpack_from(">iiIII", data, off)
            if base + 32 > len(data):
                raise ValueError(f"{label}: invalid fat slice {i}")
            out.append(Slice(base, size, data, f"{label}:fat[{i}]", cputype, cpusub))
        return out
    if struct.unpack_from("<I", data, 0)[0] not in (MH_MAGIC, MH_MAGIC_64):
        return []
    cputype, cpusub = struct.unpack_from("<ii", data, 4)
    out.append(Slice(0, len(data), data, label, cputype, cpusub))
    return out


def parse_macho(data: bytes | bytearray, label: str = "") -> MachOInfo:
    slices = iter_slices(data, label)
    if not slices:
        raise ValueError(f"{label}: not a Mach-O")
    info = MachOInfo(label, slices, [], [], [], [], [], [], len(data),
                     [], [], 0, 0)
    for sl in slices:
        if struct.unpack_from("<I", sl.data, sl.base)[0] not in (MH_MAGIC, MH_MAGIC_64):
            raise ValueError(f"{sl.label}: unsupported Mach-O magic")
        is_64 = sl.u32(0) == MH_MAGIC_64
        if not is_64:
            raise ValueError(f"{sl.label}: 32-bit Mach-O is not expected")
        ncmds = sl.u32(16)
        sizeofcmds = sl.u32(20)
        info.ncmds = ncmds
        info.sizeofcmds = sizeofcmds
        cmd_off = 32
        cmd_end = cmd_off + sizeofcmds
        first_section = sl.size
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", sl.data, sl.base + cmd_off)
            if cmdsize < 8 or cmd_off + cmdsize > cmd_end:
                raise ValueError(f"{sl.label}: invalid load command at 0x{cmd_off:x}")
            if cmd == LC_SEGMENT_64:
                segname = sl.raw(cmd_off + 8, 16).split(b"\0")[0].decode("ascii", "replace")
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from(
                    "<QQQQ", sl.data, sl.base + cmd_off + 24)
                if segname == "__LINKEDIT":
                    info.linkedit.append((cmd_off, vmaddr, vmsize, fileoff, filesize))
                nsects = struct.unpack_from("<I", sl.data, sl.base + cmd_off + 64)[0]
                sec_off = cmd_off + 72
                for _ in range(nsects):
                    sect_offset = struct.unpack_from("<I", sl.data, sl.base + sec_off + 48)[0]
                    if sect_offset and sect_offset >= 32:
                        first_section = min(first_section, sect_offset)
                    sec_off += 80
            elif cmd == LC_SYMTAB:
                symoff, nsyms, stroff, strsize = struct.unpack_from(
                    "<IIII", sl.data, sl.base + cmd_off + 8)
                info.symtab.append((cmd_off, symoff, nsyms, stroff, strsize))
            elif cmd == LC_CODE_SIGNATURE:
                sigoff, sigsize = struct.unpack_from("<II", sl.data, sl.base + cmd_off + 8)
                info.code_signature.append((sigoff, sigsize))
            elif cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64):
                cryptoff, cryptsize, cryptid = struct.unpack_from(
                    "<III", sl.data, sl.base + cmd_off + 8)
                if sl.base + cryptoff + cryptsize > len(sl.data):
                    raise ValueError(f"{sl.label}: encryption range outside file")
                info.encryption.append(Encryption(
                    cmd_off, cryptoff, cryptsize, cryptid,
                    cmd == LC_ENCRYPTION_INFO_64,
                    bytes(sl.raw(cryptoff, cryptsize)) if cryptsize else b""))
            elif cmd == LC_MAIN:
                entryoff = struct.unpack_from("<Q", sl.data, sl.base + cmd_off + 8)[0]
                info.entryoff.append(entryoff)
            elif cmd == LC_BUILD_VERSION:
                platform, minos, sdk, ntools = struct.unpack_from(
                    "<IIII", sl.data, sl.base + cmd_off + 8)
                info.build_versions.append((platform, minos, sdk))
            elif cmd == LC_LOAD_DYLIB:
                nameoff = struct.unpack_from("<I", sl.data, sl.base + cmd_off + 8)[0]
                name = bytes(sl.data[sl.base + cmd_off + nameoff:
                                       sl.base + cmd_off + cmdsize]).split(b"\0")[0]
                info.dylibs.append(name.decode("utf-8", "replace"))
            elif cmd == LC_RPATH:
                pathoff = struct.unpack_from("<I", sl.data, sl.base + cmd_off + 8)[0]
                path = bytes(sl.data[sl.base + cmd_off + pathoff:
                                       sl.base + cmd_off + cmdsize]).split(b"\0")[0]
                info.rpaths.append(path.decode("utf-8", "replace"))
            cmd_off += cmdsize
        info.first_section = min(info.first_section or len(data), first_section)
    return info


def zip_macho_entries(ipa: Path | str) -> list[tuple[str, bytes]]:
    with zipfile.ZipFile(ipa) as zf:
        return [(name, zf.read(name)) for name in zf.namelist()
                if not name.endswith("/") and is_macho(zf.read(name))]


def decode_version(value: int) -> str:
    return f"{(value >> 16) & 0xffff}.{(value >> 8) & 0xff}.{value & 0xff}"


def arm64_valid_ratio(data: bytes, base: int = 0) -> float:
    """Heuristic: count words that look like common ARM64 prologues/control flow.

    This is optional and only used by tools/check_decrypted_ipa.py when
    Capstone is available. It is not a substitute for disassembly.
    """
    import capstone  # type: ignore

    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_LITTLE_ENDIAN)
    md.detail = False
    valid = 0
    count = 0
    for insn in md.disasm(data, base):
        count += 1
        if insn.mnemonic not in ("udf", ".byte", "invalid"):
            valid += 1
    return valid / count if count else 0.0

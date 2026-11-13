#!/usr/bin/env python3
"""Rewrites the platform of every object in a static library built for iOS arm64.

Rust has no ready-made visionOS target in its stable toolchain. An iOS arm64 object is the same code for the same
processor, calling convention and system library; only the load command that names the platform differs. This
makes a copy of the library whose objects name another platform.

    retag-platform.py IN.a OUT.a xros|macos
"""
import os
import struct
import subprocess
import sys
import tempfile

# platform number, minimum OS, SDK (as Mach-O packs versions: major << 16 | minor << 8)
PLATFORMS = {"xros": (11, 2 << 16, 2 << 16, "xros"), "macos": (1, 14 << 16, 15 << 16, "macosx")}
LC_BUILD_VERSION, LC_VERSION_MIN_IPHONEOS, LC_SOURCE_VERSION = 0x32, 0x25, 0x2A


def retag(body, platform, minos, sdk):
    """The object with its platform set, or None if it is not a 64-bit Mach-O object that names one."""
    if len(body) < 32 or struct.unpack_from("<I", body, 0)[0] != 0xFEEDFACF:
        return None
    ncmds = struct.unpack_from("<I", body, 16)[0]
    data, offset, found = bytearray(body), 32, False
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == LC_BUILD_VERSION:
            struct.pack_into("<III", data, offset + 8, platform, minos, sdk)
            found = True
        elif cmd == LC_VERSION_MIN_IPHONEOS and size == 16:
            # No room for an LC_BUILD_VERSION here: the object then names no platform, and the linker takes it for any.
            struct.pack_into("<IIQ", data, offset, LC_SOURCE_VERSION, 16, 0)
            found = True
        offset += size
    return bytes(data) if found else None


def main():
    if len(sys.argv) != 4 or sys.argv[3] not in PLATFORMS:
        sys.exit(__doc__)
    source, target = sys.argv[1], os.path.abspath(sys.argv[2])
    platform, minos, sdk, sdk_name = PLATFORMS[sys.argv[3]]
    data = open(source, "rb").read()
    if data[:8] != b"!<arch>\n":
        sys.exit(source + " is not a static library")
    with tempfile.TemporaryDirectory() as work:
        pos, count, tagged, members = 8, 0, 0, []
        while pos + 60 <= len(data):
            header = data[pos:pos + 60]
            name = header[:16].decode().strip()
            size = int(header[48:58].decode().strip())
            body = data[pos + 60:pos + 60 + size]
            if name.startswith("#1/"):  # BSD long name: stored before the contents
                length = int(name[3:])
                name = body[:length].rstrip(b"\0").decode()
                body = body[length:]
            if not name.startswith("__.SYMDEF"):
                count += 1
                new = retag(body, platform, minos, sdk)
                tagged += new is not None
                member = os.path.join(work, "%05d_%s" % (count, os.path.basename(name) or "member"))
                with open(member, "wb") as out:
                    out.write(new or body)
                members.append(member)
            pos += 60 + size + (size & 1)
        if os.path.exists(target):
            os.remove(target)
        subprocess.run(["xcrun", "--sdk", sdk_name, "libtool", "-static", "-no_warning_for_no_symbols", "-o", target] + members,
                       check=True, stderr=subprocess.DEVNULL)
    print("%s: %d members, %d retagged for %s" % (target, count, tagged, sys.argv[3]))


main()

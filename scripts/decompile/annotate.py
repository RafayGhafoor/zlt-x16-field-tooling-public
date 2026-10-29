#!/usr/bin/env python3
"""Resolve the string literals in a Ghidra / r2ghidra dump of an ARM PIC binary.

Why this is needed
------------------
The vendor binaries are built `-fPIC` with GCC's ARM "literal pool" idiom: a
string is addressed as *two* instructions,

    ldr   r1, [pc, #0x1c4]    ; r1 = <offset 0x40aa>     (a dword in .text)
    add   r1, pc              ; r1 = pc + r1 = &"..."    (in .rodata)

so both decompilers print the operand as a *sum of two addresses* instead of the
string:

    r2ghidra:  savelog(1, *0x41e4 + 0x3ede, *0x41e0 + 0x41d2, 0x589)
    Ghidra:    savelog(1, DAT_000141e4 + 0x13ede, DAT_000141e0 + 0x141d2, 0x589)

The dword at the pool address is the *low* half of the sum and the pc of the `add`
is the high half, so the target is `dword(pool) + pc`.  This script computes that
for every `X + Y` pair in the dump and appends the literal it points at.

The one wrinkle: Ghidra imports a PIE at an arbitrary image base (0x10000 for these
binaries) while the literal-pool dwords are link-time offsets, so both halves of the
sum are shifted by that base.  `--base` (or `--auto-base`) subtracts it before adding
and adds it back to the result.  r2 loads at 0, so `--base 0`.

Usage
-----
    annotate.py <decomp.c> [--base 0x10000|auto] [-o out.c]
    annotate.py <decomp.c>          # default: auto-detect, print to stdout
"""
import argparse
import re
import struct
import sys

# Both decompilers' spellings of "the dword at <pool>".  r2ghidra writes `*0x1234`,
# Ghidra writes `DAT_00001234`; the pool address is always >= 4 hex digits.
POOL_PAT = re.compile(r"(?:DAT_|\*\s*0x)([0-9a-f]{4,8})\s*\+\s*(?:0x)?([0-9a-f]{4,8})\b")


class Elf:
    """Just enough ELF to map (vaddr -> file offset) for PT_LOAD segments."""

    def __init__(self, path):
        self.data = open(path, "rb").read()
        d = self.data
        if d[:4] != b"\x7fELF":
            raise SystemExit("%s: not an ELF" % path)
        self.is64 = d[4] == 2
        end = "<" if d[5] == 1 else ">"
        if self.is64:
            e_phoff, = struct.unpack_from(end + "Q", d, 0x20)
            e_phentsize, e_phnum = struct.unpack_from(end + "HH", d, 0x36)
        else:
            e_phoff, = struct.unpack_from(end + "I", d, 0x1C)
            e_phentsize, e_phnum = struct.unpack_from(end + "HH", d, 0x2A)
        self.segs = []          # (vaddr, file offset, filesz, flags)
        for i in range(e_phnum):
            off = e_phoff + i * e_phentsize
            if self.is64:
                p_type, p_flags, p_offset, p_vaddr, _pa, p_filesz, _msz = \
                    struct.unpack_from(end + "IIQQQQQ", d, off)
            else:
                p_type, p_offset, p_vaddr, _pa, p_filesz, _msz, p_flags = \
                    struct.unpack_from(end + "IIIIIII", d, off)
            if p_type == 1:     # PT_LOAD
                self.segs.append((p_vaddr, p_offset, p_filesz, p_flags))

    def read(self, va, n):
        for vaddr, off, sz, _fl in self.segs:
            if vaddr <= va < vaddr + sz:
                fo = off + (va - vaddr)
                return self.data[fo:fo + min(n, sz - (va - vaddr))]
        return None

    def dword(self, va):
        b = self.read(va, 4)
        if b is None or len(b) < 4:
            return None
        return struct.unpack("<I", b)[0] if self.segs else None

    def cstr(self, va, maxlen=240):
        b = self.read(va, maxlen)
        if not b:
            return None
        end = b.find(b"\x00")
        if end >= 0:
            b = b[:end]
        if not b:
            return None
        try:
            s = b.decode("utf-8")
        except UnicodeDecodeError:
            return None
        # a decoded "string" that starts mid-literal or is control-heavy is noise
        if any(ord(c) < 9 for c in s):
            return None
        return s


def resolve(elf, pool, pc, base):
    """ELF vaddr of `dword(pool) + pc` for a dump using image base `base`, or None.

    Returns the file's own vaddr (base already subtracted), because that is what
    `Elf.read`/`cstr` take; the caller re-adds nothing and just prints it.
    """
    v = elf.dword(pool - base)
    if v is None:
        return None
    t = v + (pc - base)
    # the sum must land inside a mapped segment (the caller then checks that it
    # actually starts a printable string — that is what rejects the misses)
    for vaddr, _off, sz, _fl in elf.segs:
        if vaddr <= t < vaddr + sz:
            break
    else:
        return None
    return t


def guess_base(elf, dump):
    """Pick the image base that makes the most pool references resolve to strings."""
    best, best_n = 0, -1
    for base in (0x10000, 0x0, 0x8000, 0x1000, 0x400000):
        n = 0
        for m in POOL_PAT.finditer(dump[:400000]):
            t = resolve(elf, int(m.group(1), 16), int(m.group(2), 16), base)
            if t is not None and elf.cstr(t) is not None:
                n += 1
        if n > best_n:
            best, best_n = base, n
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("decomp")
    ap.add_argument("-o", "--out")
    ap.add_argument("-e", "--elf", help="binary the dump came from (default: $TARGET)")
    ap.add_argument("--base", default="auto",
                    help="image base used in the dump ('auto', 0, 0x10000, ...)")
    a = ap.parse_args()

    elf_path = a.elf or __import__("os").environ.get("TARGET")
    if not elf_path:
        raise SystemExit("need --elf <binary> (or $TARGET)")
    elf = Elf(elf_path)
    dump = open(a.decomp).read()

    base = guess_base(elf, dump) if a.base == "auto" else int(a.base, 0)
    sys.stderr.write("annotate: elf=%s base=0x%x\n" % (elf_path, base))

    cache = {}
    out = []
    for line in dump.splitlines():
        m = POOL_PAT.search(line)
        if m:
            t = resolve(elf, int(m.group(1), 16), int(m.group(2), 16), base)
            if t is not None:
                if t not in cache:
                    # the code sometimes pre-increments the pointer before the first
                    # use (`p = base - 1; while (..) *++p`), so the literal can start
                    # up to 3 bytes past the computed address.
                    cache[t] = None
                    for delta in (0, 1, 2, 3):
                        cand = elf.cstr(t + delta)
                        if cand:
                            cache[t] = (cand, delta)
                            break
                hit = cache[t]
                s = hit[0] if hit else None
                if s:
                    esc = (s.replace("\\", "\\\\").replace('"', '\\"')
                            .replace("\n", "\\n").replace("\r", "\\r"))
                    line = '%s   // 0x%x%s "%s"' % (line, t, '' if not hit[1] else '+%d' % hit[1], esc)
        out.append(line)

    text = "\n".join(out) + "\n"
    if a.out:
        open(a.out, "w").write(text)
        sys.stderr.write("annotate: %d literals resolved -> %s\n"
                         % (len(cache), a.out))
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()

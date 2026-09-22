#!/usr/bin/env python3
"""Turn the bare `pc:` values in a watch CIQ_LOG.YML into file:line frames.

A Connect IQ crash log off a user's watch (GARMIN/APPS/LOGS/CIQ_LOG.YML) often
carries only raw program counters. They are meaningless without the debug.xml
of the EXACT build that produced them - see debug-symbols/README.md.

    tools/decode-crash.py CIQ_LOG.YML debug-symbols/b35.debug.xml

Program counters are HEX in the log and DECIMAL in debug.xml, which is the step
that catches everyone out. Frames are reported as the nearest symbol at or
below the pc, with the next entry shown when the match is not exact, because a
pc can land mid-instruction or on a return address.
"""
import re
import sys
import xml.etree.ElementTree as ET
from bisect import bisect_right


def symbol_part_number(path):
    """The partNumber the debug.xml was built for, or None."""
    for e in ET.parse(path).getroot().iter():
        pn = e.get("partNumber")
        if pn:
            return pn
    return None


def device_for(part_number):
    """Resolve a part number to a device id via the installed SDK, or None."""
    import json, glob, os
    root = os.path.expanduser(
        "~/Library/Application Support/Garmin/ConnectIQ/Devices")
    for f in glob.glob(os.path.join(root, "*", "compiler.json")):
        try:
            cfg = json.load(open(f))
        except Exception:
            continue
        for p in cfg.get("partNumbers", []):
            if p.get("number") == part_number:
                return os.path.basename(os.path.dirname(f))
    return None


def describe(part_number):
    dev = device_for(part_number) if part_number else None
    if part_number and dev:
        return f"{part_number} ({dev})"
    return part_number or "unknown"


def load_symbols(path):
    entries = []
    for e in ET.parse(path).getroot().iter("entry"):
        pc = e.get("pc")
        if pc is None:
            continue
        entries.append((int(pc), e.get("filename") or "?",
                        e.get("lineNum") or "?", e.get("symbol") or "?"))
    entries.sort(key=lambda r: r[0])
    return entries


def resolve(entries, pc):
    """Nearest entry at or below pc, plus the following one for context."""
    i = bisect_right([r[0] for r in entries], pc)
    below = entries[i - 1] if i > 0 else None
    above = entries[i] if i < len(entries) else None
    return below, above


def short(path):
    m = re.search(r"/(source|bin)/.*", path)
    return m.group(0).lstrip("/") if m else path.rsplit("/", 1)[-1]


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    log_path, sym_path = argv[1], argv[2]
    entries = load_symbols(sym_path)
    if not entries:
        print(f"no pc entries in {sym_path}", file=sys.stderr)
        return 1

    text = open(log_path, encoding="utf-8", errors="replace").read()

    # Program counters are per-device. Decoding against another device's build
    # produces confident, wrong file:line, so refuse to do it quietly.
    log_pn = None
    m = re.search(r"Part-Number:\s*'?([0-9A-Za-z-]+)'?", text)
    if m:
        log_pn = m.group(1)
    sym_pn = symbol_part_number(sym_path)
    if log_pn and sym_pn and log_pn != sym_pn:
        print(f"MISMATCH: log is from {describe(log_pn)} but "
              f"{short(sym_path)} was built for {describe(sym_pn)}.\n"
              f"          Frames below would be WRONG. Build that tag for that "
              f"device and retry.", file=sys.stderr)
        return 3
    if not sym_pn:
        print(f"note: {short(sym_path)} carries no partNumber; cannot confirm "
              f"it matches this log's device.", file=sys.stderr)
    pcs = [int(h, 16) for h in re.findall(r"pc:\s*(?:0x)?([0-9a-fA-F]+)", text)]
    if not pcs:
        print(f"no 'pc:' values found in {log_path}", file=sys.stderr)
        return 1

    for line in text.splitlines():
        s = line.strip()
        if s.startswith(("Error:", "Details:", "Time:", "Part-Number:",
                         "Firmware-Version:", "App-Name:", "App-Version:")):
            print(s)

    print(f"\n{len(pcs)} frame(s), decoded against {short(sym_path)}"
          f" [{describe(sym_pn)}]:\n")
    for depth, pc in enumerate(pcs):
        below, above = resolve(entries, pc)
        if below is None:
            print(f"  #{depth}  0x{pc:08x}  <before first symbol>")
            continue
        bpc, bfile, bline, bsym = below
        exact = "" if bpc == pc else f"  (nearest below, -{pc - bpc})"
        print(f"  #{depth}  0x{pc:08x}  {bsym}() at {short(bfile)}:{bline}{exact}")
        if bpc != pc and above is not None:
            apc, afile, aline, asym = above
            print(f"{'':>25}or {asym}() at {short(afile)}:{aline}"
                  f"  (nearest above, +{apc - pc})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

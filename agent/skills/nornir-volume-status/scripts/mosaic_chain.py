"""Read-only XML check of each channel's mosaic chain (Stage -> Prune -> Translated_Prune -> Grid).
Reports checksum-link mismatches, lock state, duplicate and missing Grid nodes.
usage: mosaic_chain.py <block_dir>"""
import sys, glob, os, xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime, timezone

CHAIN = ('Stage', 'Prune', 'Translated_Prune', 'Grid')
block = sys.argv[1]
stats = Counter(); bad = []; dup = []; nogrid = []; stale = []
for f in sorted(glob.glob(os.path.join(block, '[0-9]*', '*', 'VolumeData.xml'))):
    if '/Registered' in f:
        continue
    try:
        root = ET.parse(f).getroot()
    except ET.ParseError:
        bad.append(f'{f}: unparseable'); continue
    ts = [t for t in root if t.tag == 'Transform']
    names = Counter(t.get('Name') for t in ts)
    if names['Grid'] > 1: dup.append(f)
    if names['Grid'] == 0: nogrid.append(f); continue
    by = {t.get('Name'): t for t in ts}
    stats['channels'] += 1
    for n in CHAIN:
        t = by.get(n)
        if t is None:
            continue
        locked = t.get('Locked') == '1'
        stats[f'{n}_locked' if locked else f'{n}_unlocked'] += 1
        # C13-B012: a .mosaic whose mtime is newer than its ValidationTime gets re-checksummed in the
        # new format, never matches, and is deleted by the next validating Select unless locked.
        vt, path = t.get('ValidationTime'), t.get('Path')
        if vt and path:
            try:
                v = datetime.fromisoformat(vt)
                v = v if v.tzinfo else v.replace(tzinfo=timezone.utc)
                m = os.stat(os.path.join(os.path.dirname(f), path)).st_mtime
                if m - v.timestamp() > 2:
                    stale.append(f"{os.path.relpath(f, block)}: {n} mtime > ValidationTime" + (" (locked)" if locked else " (UNLOCKED)"))
            except (ValueError, OSError):
                pass
        inp = t.get('InputTransform')
        if inp and inp in by:
            want = t.get('InputTransformChecksum'); have = by[inp].get('Checksum')
            if want and have and want != have:
                bad.append(f"{os.path.relpath(f, block)}: {n}.InputTransformChecksum != {inp}.Checksum")
print(f"  channels with Grid: {stats['channels']}; missing Grid: {len(nogrid)}; duplicate Grid: {len(dup)}")
print('  locks: ' + ', '.join(f"{n} {stats[n + '_locked']}L/{stats[n + '_unlocked']}U" for n in CHAIN))
print(f"  chain checksum mismatches: {len(bad)}")
unl = [x for x in stale if x.endswith('(UNLOCKED)')]
print(f"  mtime newer than ValidationTime (C13-B012 risk): {len(stale)}, unlocked: {len(unl)}")
for x in unl[:10]: print('    ' + x)
for b in bad[:10]: print('    ' + b)
for d in dup[:5]: print('    duplicate Grid: ' + os.path.relpath(d, block))
for d in nogrid[:5]: print('    no Grid: ' + os.path.relpath(d, block))

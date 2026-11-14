#!/usr/bin/env python3
"""Compare the output directory of the Bash tool with the one of the PowerShell tool (same mock, same frozen clock).

usage: compare.py BASH_DIR PS_DIR   -> prints SAME/DIFF per file, exit 1 on any difference.
Only the tool version may differ (JSON "version", HTML payload "version"); everything else must be identical.
"""
import difflib, json, os, re, sys

def norm(path):
    s = open(path, encoding='utf-8').read()
    if path.endswith('.json'):
        d = json.loads(s)
        if isinstance(d, dict):
            for k in ('version', 'tool', 'tool_version'): d.pop(k, None)
        return json.dumps(d, indent=1, sort_keys=True)
    if path.endswith('.html'):
        m = re.search(r'<script id="data" type="application/json">(.*?)</script>', s, re.S)
        if m:
            d = json.loads(m.group(1).replace('<\\/', '</')); d.pop('version', None)
            s = s[:m.start(1)] + json.dumps(d, indent=1, sort_keys=True) + s[m.end(1):]
        s = re.sub(r'v\d+\.\d+\.\d+', 'vX', s)
    return s

def main(a, b):
    fa, fb = sorted(os.listdir(a)), sorted(os.listdir(b)); bad = 0
    for f in sorted(set(fa) | set(fb)):
        if f not in fb: print('MISSING', f); bad += 1; continue
        if f not in fa: print('EXTRA', f); bad += 1; continue
        x, y = norm(os.path.join(a, f)), norm(os.path.join(b, f))
        if x == y: print('SAME', f); continue
        bad += 1; print('DIFF', f)
        for l in list(difflib.unified_diff(x.splitlines(), y.splitlines(), 'bash', 'ps', lineterm='', n=1))[:30]: print('   ', l[:300])
    return 1 if bad else 0

if __name__ == '__main__': sys.exit(main(sys.argv[1], sys.argv[2]))

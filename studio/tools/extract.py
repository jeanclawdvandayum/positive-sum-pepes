#!/usr/bin/env python3
"""Extract studio spec data from the live generator state.
Run from repo root: python3 studio/tools/extract.py"""
import json
import os
import shutil
import sys

sys.path.insert(0, 'script')
import gen_pepe_art as G  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = os.path.join(ROOT, 'spec')
os.makedirs(os.path.join(SPEC, 'golden'), exist_ok=True)


def rgb(t):
    return list(t)


out = {
    'base_grid': G._base(),
    'letters': {ch: slot for ch, slot in G.C2I.items()},
    'size': G.SIZE,
    'palettes': {
        'skins': [{'name': n, 'slots': {str(k): rgb(v)
                                         for k, v in s.items()}}
                  for n, s in G.SKINS],
        'fixed': {str(k): rgb(v) for k, v in G.FIXED.items()},
        'irises': [{'name': n, 'rgb': rgb(c)} for n, c in G.IRISES],
        'backgrounds': [{'name': n, 'rgb': rgb(c)}
                        for n, c in G.BACKGROUNDS],
    },
}
with open(os.path.join(SPEC, 'psp_state.json'), 'w') as f:
    json.dump(out, f)

shutil.copyfile('src/PepeArtData.sol',
                os.path.join(SPEC, 'golden', 'PepeArtData.sol'))

import hashlib  # noqa: E402
h = hashlib.sha256(
    open('src/PepeArtData.sol', 'rb').read()).hexdigest()
with open(os.path.join(SPEC, 'golden', 'PepeArtData.sol.sha256'), 'w') as f:
    f.write(h + '\n')
print('base grid: %d rows' % len(out['base_grid']))
print('letters: %s' % ''.join(sorted(out['letters'])))
print('golden sha256: %s' % h)

#!/usr/bin/env python3
"""Fail closed on production runtime size and EIP-3860 initcode size."""
import json
from pathlib import Path
checked = 0
for artifact in sorted(Path('out').glob('*.sol/*.json')):
    data = json.loads(artifact.read_text())
    meta = data.get('metadata', {})
    if isinstance(meta, str): meta = json.loads(meta)
    targets = meta.get('settings', {}).get('compilationTarget', {})
    if not any(p.startswith('src/') for p in targets): continue
    runtime = data.get('deployedBytecode', {}).get('object', '').removeprefix('0x')
    init = data.get('bytecode', {}).get('object', '').removeprefix('0x')
    if not runtime: continue
    n, i = len(runtime)//2, len(init)//2
    if artifact.stem == 'VectorPepeDescriptor':
        print(f'Excluded prototype VectorPepeDescriptor: {n} bytes; NOT DEPLOYABLE, not used by DeployPSP')
        continue
    assert n <= 24576, f'{artifact.stem}: runtime {n} exceeds EIP-170'
    assert i <= 49152, f'{artifact.stem}: initcode {i} exceeds EIP-3860 before constructor args'
    if artifact.stem in ('CurveHook', 'PSPFactory', 'HookDeployer', 'HookInitCode'):
        assert n < 24076, f'{artifact.stem}: less than 500 bytes runtime headroom'
        print(f'{artifact.stem}: runtime {n}, initcode {i}')
    elif artifact.stem == 'SineV3Math':
        assert n < 24076, f'{artifact.stem}: less than 500 bytes runtime headroom'
        assert i + 4 * 32 <= 49152, 'SineV3Math: initcode plus shard constructor arguments exceeds EIP-3860'
        print(f'{artifact.stem}: runtime {n}, initcode {i}')
    checked += 1
assert checked > 0, 'No production artifacts; run forge build first'
print(f'Size gate: {checked} production artifacts passed (constructor arguments require deployment checks).')

# Data contracts return a packed runtime from their constructors. The compiler's
# default deployedBytecode is unreachable and cannot establish their true size.
data_manifest = json.loads(Path('scripts/sine_v3_data.json').read_text())
assert len(data_manifest['shards']) == 4, 'Unexpected sine data shard count'
for shard in data_manifest['shards']:
    assert 1 < shard['bytes'] <= 24576, f"{shard['contract']}: returned runtime exceeds EIP-170"
    print(f"{shard['contract']}: returned data runtime {shard['bytes']} bytes")

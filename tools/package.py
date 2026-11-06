#!/usr/bin/env python3
"""Create a ZIP with the Windows install helper and all portable project files."""
from pathlib import Path
import argparse
import zipfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
args = parser.parse_args()
paths = [ROOT/'README.md', ROOT/'LICENSE']
for folder in ('src','dist','tools','docs','examples','tests'):
    paths.extend(p for p in (ROOT/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
with zipfile.ZipFile(args.output, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(paths):
        archive.write(path, 'LayoutAssistant-0.2.0/'+path.relative_to(ROOT).as_posix())
print(args.output)

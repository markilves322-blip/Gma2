#!/usr/bin/env python3
"""Release checks: actual Lua 5.3, deterministic bundle, MA2 descriptor and offline flow."""
import importlib.util
import os
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
lua = os.environ.get('LUA') or shutil.which('lua5.3') or shutil.which('lua')
if not lua:
    raise SystemExit('Install Lua 5.3 or set LUA=/absolute/path/to/lua')
version = subprocess.check_output([lua, '-e', 'io.write(_VERSION)'], text=True)
if version != 'Lua 5.3':
    raise SystemExit(f'Lua 5.3 required for release checks, found {version}')
spec = importlib.util.spec_from_file_location('builder', ROOT / 'tools/build.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
assert (ROOT / 'dist/layout_assistant.lua').read_text() == builder.bundle(), 'Stale dist: run tools/build.py'
manifest = ET.parse(ROOT / 'dist/layout_assistant.xml').getroot()
ns = {'m': 'http://schemas.malighting.de/grandma2/xml/MA'}
plugin = manifest.find('m:Plugin', ns)
assert plugin is not None and plugin.get('execute_on_load') == '0'
assert plugin.get('luafile') == 'layout_assistant.lua' and len(plugin) == 0, 'Expected MA2 luafile descriptor'
for path in sorted(ROOT.rglob('*.lua')):
    subprocess.run([lua, '-e', 'assert(loadfile(os.getenv("LA_CHECK_FILE")))'],
                   env=dict(os.environ, LA_CHECK_FILE=str(path)), check=True)
subprocess.run([lua, 'tests/run.lua'], check=True)
with tempfile.TemporaryDirectory(prefix='layout-assistant-') as tmp:
    output, svg = Path(tmp) / 'result.xml', Path(tmp) / 'preview.svg'
    command = [lua, 'tools/offline.lua', 'examples/synthetic-layout.xml', 'examples/recipe.lua', str(output)]
    subprocess.run(command, check=True)
    first = output.read_bytes()
    second = subprocess.run(command, capture_output=True, text=True)
    assert second.returncode != 0 and 'Refusing to overwrite' in second.stderr
    assert output.read_bytes() == first
    ET.parse(output)
    subprocess.run(['python3', 'tools/preview.py', 'examples/synthetic-layout.xml', str(output), str(svg)], check=True)
    ET.parse(svg)
print('Release checks passed: Lua 5.3, bundle, MA2 descriptor, offline XML/SVG and overwrite refusal.')

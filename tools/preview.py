#!/usr/bin/env python3
"""Render exported fixture centres before/after to a standalone SVG. No GUI needed."""
import html
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

NS = {'m': 'http://schemas.malighting.de/grandma2/xml/MA'}
COLORS = ['#38bdf8', '#fb923c', '#a78bfa', '#34d399', '#f472b6', '#facc15']

def points(path):
    tree = ET.parse(path)
    result = []
    for node in tree.findall('.//m:LayoutSubFix', NS):
        ref = node.find('m:Subfixture', NS)
        if ref is not None and ref.get('fix_id') not in (None, '0'):
            result.append((int(ref.get('fix_id')), ref.get('sub_index', 'root'),
                           float(node.get('center_x')), float(node.get('center_y'))))
    if not result:
        raise ValueError('No fixture centres')
    return result

def render(before, after):
    both = before + after
    xs, ys = [p[2] for p in both], [p[3] for p in both]
    xmin, xmax, ymin, ymax = min(xs), max(xs), min(ys), max(ys)
    width, height = max(xmax-xmin, 1), max(ymax-ymin, 1)
    scale = min(1050 / width, 240 / height)
    colors = {fid: COLORS[i % len(COLORS)] for i, fid in enumerate(sorted({p[0] for p in both}))}
    svg = ['<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="800" viewBox="0 0 1200 800">',
           '<title>Layout Assistant: до и после</title>',
           '<rect width="1200" height="800" fill="#111827"/>',
           '<g font-family="sans-serif" fill="#f3f4f6">',
           '<text x="40" y="40" font-size="24">Layout Assistant · синтетический пример</text>',
           '<text x="40" y="68" font-size="15">Подпись: Fixture ID / raw sub_index. Координата Y направлена вверх.</text>']
    for label, data, offset in [('До', before, 120), ('После', after, 460)]:
        svg.append(f'<text x="40" y="{offset}" font-size="22">{label}</text>')
        svg.append(f'<rect x="30" y="{offset+12}" width="1140" height="290" rx="8" fill="#1f2937"/>')
        for fid, index, x, y in data:
            px, py = 75+(x-xmin)*scale, offset+40+(ymax-y)*scale
            text = html.escape(f'{fid}/{index}')
            svg += [f'<circle cx="{px:.2f}" cy="{py:.2f}" r="6" fill="{colors[fid]}"/>',
                    f'<text x="{px+8:.2f}" y="{py-8:.2f}" font-size="12">{text}</text>']
    return '\n'.join(svg+['</g></svg>'])+'\n'

if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit('Usage: python3 tools/preview.py before.xml after.xml NEW-preview.svg')
    svg = render(points(sys.argv[1]), points(sys.argv[2]))
    with Path(sys.argv[3]).open('x', encoding='utf-8') as output:
        output.write(svg)

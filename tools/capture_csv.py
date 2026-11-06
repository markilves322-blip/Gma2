#!/usr/bin/env python3
"""Explicit CSV/TSV column mapping to MA2 Layout anchors; never edits a show/patch."""
import argparse
import csv
import json
import math
from pathlib import Path


def number(value):
    value = str(value).strip()
    # Delimiter is explicit; decimal comma is supported without guessing units.
    n = float(value.replace(',', '.'))
    if not math.isfinite(n) or abs(n) > 1_000_000:
        raise ValueError(f'Invalid finite coordinate: {value!r}')
    return n


def fixture_id(value):
    n = number(value)
    if n <= 0 or n != int(n):
        raise ValueError(f'Invalid Fixture ID: {value!r}')
    return int(n)


def convert(csv_text, profile):
    columns = profile['columns']
    horizontal, vertical = profile['horizontal_axis'], profile['vertical_axis']
    if horizontal not in ('x', 'y', 'z') or vertical not in ('x', 'y', 'z') or horizontal == vertical:
        raise ValueError('Select two different explicit axes: x, y, z')
    scale = number(profile.get('scale', 1))
    if scale <= 0:
        raise ValueError('scale must be positive')
    signs = [number(profile.get('horizontal_sign', 1)), number(profile.get('vertical_sign', 1))]
    if any(s not in (-1, 1) for s in signs):
        raise ValueError('Axis signs must be +1 or -1')
    origin = profile.get('origin', {})
    origins = {axis: number(origin.get(axis, 0)) for axis in ('x', 'y', 'z')}
    delimiter = profile.get('delimiter', ',')
    if delimiter not in (',', ';', '\t'):
        raise ValueError('delimiter must be comma, semicolon or tab')
    reader = csv.DictReader(csv_text.lstrip('\ufeff').splitlines(), delimiter=delimiter)
    required = {columns[k] for k in ('id', horizontal, vertical)}
    if 'rotation_delta' in columns:
        required.add(columns['rotation_delta'])
    if not reader.fieldnames or len(set(reader.fieldnames)) != len(reader.fieldnames):
        raise ValueError('Missing/duplicate CSV headers')
    missing = required - set(reader.fieldnames)
    if missing:
        raise ValueError(f'Missing CSV columns: {sorted(missing)}; available: {reader.fieldnames}')
    id_map = profile.get('id_map')
    placements, seen, warnings, projected = [], set(), [], {}
    for row_number, row in enumerate(reader, 2):
        try:
            if None in row or any(v is None for v in row.values()):
                raise ValueError('Malformed CSV field count')
            capture_id = str(fixture_id(row[columns['id']]))
            if id_map is not None:
                if capture_id not in id_map:
                    raise ValueError(f'ID {capture_id} missing from explicit id_map')
                fid = fixture_id(id_map[capture_id])
            else:
                fid = fixture_id(capture_id)
            if fid in seen:
                raise ValueError(f'Duplicate target Fixture ID {fid}')
            seen.add(fid)
            x = number((number(row[columns[horizontal]]) - origins[horizontal]) * scale * signs[0])
            y = number((number(row[columns[vertical]]) - origins[vertical]) * scale * signs[1])
            angle = number(row[columns['rotation_delta']]) if 'rotation_delta' in columns else 0
            # Only numbers enter the normalized format; no Lua or command generation.
            placements.append({'fix_id': fid, 'x': x, 'y': y, 'rotation_delta': angle})
            key = (round(x, 6), round(y, 6))
            if key in projected:
                warnings.append(f'Projected centres coincide: {projected[key]} and {fid}; review layers/offsets')
            projected[key] = fid
        except (ValueError, TypeError, KeyError) as exc:
            raise ValueError(f'CSV row {row_number}: {exc}') from exc
    if not placements:
        raise ValueError('Empty fixture list')
    lines = ['fix_id\tx\ty\trotation_delta']
    for p in placements:
        lines.append(f"{p['fix_id']}\t{p['x']:.6f}\t{p['y']:.6f}\t{p['rotation_delta']:.6f}")
    return '\n'.join(lines) + '\n', {'profile': profile, 'placements': placements,
        'warnings': warnings, 'id_match': 'explicit map' if id_map is not None else 'ASSUMED: Capture ID = MA2 Fixture ID'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv', type=Path)
    parser.add_argument('profile', type=Path, help='JSON: columns, axes, signs, scale, origin, optional id_map')
    parser.add_argument('output', type=Path, help='NEW normalized .tsv file')
    parser.add_argument('--encoding', default='utf-8-sig', help='Use cp1251 only if the export requires it')
    args = parser.parse_args()
    if args.csv.stat().st_size > 16 * 1024 * 1024:
        parser.error('CSV exceeds 16 MiB')
    tsv, report = convert(args.csv.read_text(encoding=args.encoding), json.loads(args.profile.read_text(encoding='utf-8-sig')))
    report_path = args.output.with_suffix(args.output.suffix + '.json')
    if args.output.exists() or report_path.exists():
        parser.error('Output exists; choose NEW filenames')
    with args.output.open('x', encoding='utf-8', newline='') as out:
        out.write(tsv)
    with report_path.open('x', encoding='utf-8') as out:
        json.dump(report, out, ensure_ascii=False, indent=2)
    print(f'{len(report["placements"])} fixture centres; {report["id_match"]}')
    for warning in report['warnings']:
        print('WARNING:', warning)


if __name__ == '__main__':
    main()

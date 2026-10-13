#!/usr/bin/env python3
"""Build an additive scanner HBA candidate without touching the active database."""
import argparse
from pathlib import Path


def candidate(active: str, rules: str) -> str:
    if rules.strip() in active:
        return active
    if 'makepad_scan' in active:
        raise ValueError('Existing scanner rules differ; review them before changing access')
    lines = active.splitlines(keepends=True)
    fallback = [i for i, line in enumerate(lines) if line.split() == ['host', 'all', 'all', 'all', 'scram-sha-256']]
    if len(fallback) != 1:
        raise ValueError('Expected exactly one shared fallback rule')
    lines.insert(fallback[0], rules.rstrip() + '\n')
    return ''.join(lines)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('active', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    rules = Path(__file__).resolve().parents[1] / 'config/makepad-scan-hba.conf'
    value = candidate(args.active.read_text(), rules.read_text())
    with args.output.open('x') as output:
        output.write(value)

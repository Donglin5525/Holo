#!/usr/bin/env python3
"""全模块源码线索清单；命中仅供逐项核对，不代表体验缺陷或验收通过。"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Holo/Holo APP/Holo/Holo'
RULES = {
    'legacy_secondary': re.compile(r'(?<!\w)holoTextSecondary\b'),
    'dimmed_secondary': re.compile(r'holo(?:Tool)?TextSecondary\.opacity\('),
    'fixed_font': re.compile(r'\.font\(\.system\(size:\s*[\d.]+'),
    'inline_rgb': re.compile(r'Color\((?:hex:|red:)'),
    'small_square': re.compile(r'\.frame\(width:\s*(\d+(?:\.\d+)?),\s*height:\s*\1\)'),
    'ignored_error': re.compile(r'try\?'),
}


def scan():
    modules = {}
    for folder in ('Views', 'Components'):
        for path in sorted((APP / folder).rglob('*.swift')):
            parts = path.relative_to(APP / folder).parts
            module = parts[0] if folder == 'Views' and len(parts) > 1 else folder + '/公共'
            info = modules.setdefault(module, {'files': 0, 'candidates': []})
            info['files'] += 1
            for line_number, line in enumerate(path.read_text().splitlines(), 1):
                if line.lstrip().startswith('//'):
                    continue
                for rule, pattern in RULES.items():
                    match = pattern.search(line)
                    if not match:
                        continue
                    if rule == 'small_square' and float(match.group(1)) >= 44:
                        continue
                    info['candidates'].append({'rule': rule, 'file': str(path.relative_to(ROOT)),
                                               'line': line_number, 'text': line.strip()})
    return {'meaning': '源码候选，需结合文字/图标、热区外扩、数据色与业务错误语义核对；不是 bug 数量。',
            'modules': modules}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', type=Path, help='输出候选明细，建议放 /tmp')
    args = parser.parse_args()
    result = scan()
    for name, info in sorted(result['modules'].items()):
        counts = {rule: sum(c['rule'] == rule for c in info['candidates']) for rule in RULES}
        print(f'{name}: {info["files"]} files, ' + ', '.join(f'{k}={v}' for k, v in counts.items()))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(result['meaning'])


if __name__ == '__main__':
    main()

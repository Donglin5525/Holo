#!/usr/bin/env python3
"""业务色与品牌契约独立验证；源码检查不能替代页面渲染和真机体验。"""
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Holo/Holo APP/Holo/Holo'
COLORS = APP / 'Assets.xcassets/Colors'


def rgb(name, dark):
    entries = json.loads((COLORS / f'{name}.colorset/Contents.json').read_text())['colors']
    def is_dark(entry):
        return any(a.get('appearance') == 'luminosity' and a.get('value') == 'dark'
                   for a in entry.get('appearances', []))
    entry = next(e for e in entries if is_dark(e) == dark)
    components = entry['color']['components']
    def channel(value):
        return int(value, 16) / 255 if value.startswith('0x') else float(value)
    return [channel(components[k]) for k in ('red', 'green', 'blue')]


def composite(foreground, background, opacity):
    return [fg * opacity + bg * (1 - opacity) for fg, bg in zip(foreground, background)]


def luminance(values):
    linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in values]
    return sum(v * w for v, w in zip(linear, (0.2126, 0.7152, 0.0722)))


def contrast_values(foreground, background):
    hi, lo = sorted([luminance(foreground), luminance(background)], reverse=True)
    return (hi + .05) / (lo + .05)


def contrast(foreground, background, dark):
    return contrast_values(rgb(foreground, dark), rgb(background, dark))


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def check_text(dark):
    count = 0
    for fg in ('ToolText', 'ToolTextSecondary', 'ToolWarning', 'ToolSuccess', 'ToolError', 'ToolInfo', 'ToolAI'):
        for bg in ('ToolBackground', 'ToolSurface', 'ToolInset'):
            value = contrast(fg, bg, dark)
            require(value >= 4.5, f'{fg}/{bg}: {value:.2f} < 4.5')
            count += 1
            if fg not in ('ToolText', 'ToolTextSecondary'):
                # 状态说明常放在该色 10% 淡底上，检查最终合成后的实际底色。
                tinted = composite(rgb(fg, dark), rgb(bg, dark), .1)
                value = contrast_values(rgb(fg, dark), tinted)
                require(value >= 4.5, f'{fg}/{bg}+10% tint: {value:.2f} < 4.5')
                count += 1
    return f'{count} 组正文/状态文字及合成淡底 ≥4.5'


def check_action(dark):
    # 沿用已批准的品牌色门槛；这不构成普通按钮文字的 WCAG AA 认证。
    for bg in ('ToolBackground', 'ToolSurface', 'ToolInset'):
        value = contrast('ToolAction', bg, dark)
        require(value >= 3, f'ToolAction/{bg}: {value:.2f} < 3')
    value = contrast('ToolOnAction', 'ToolAction', dark)
    require(value >= 3, f'ToolOnAction/ToolAction: {value:.2f} < 3')
    return '4 组品牌色 ≥3（既有产品约定）'


def block(source, start, end):
    offset = source.index(start)
    return source[offset:source.index(end, offset)]


def check_brand():
    home = (APP / 'Views/HomeView.swift').read_text()
    button = (APP / 'Components/DailyKanbanEntryButton.swift').read_text()
    background = block(home, 'private var backgroundDecorations:', 'private func decorDot')
    sphere = block(button, 'private var sphere:', 'private var captionText:')
    require('holoTool' not in background + sphere, '业务色侵入首页品牌绘制')
    # 以当前已采用的绝对时间动画契约验证，旧 repeatForever 文本/代码哈希不再适用。
    markers = ['TimelineView(.animation(minimumInterval: 0.1, paused: !backgroundMotionActive))',
               '0.5 + 0.5 * sin(2 * .pi * t / 6)', '(t / 60).truncatingRemainder(dividingBy: 1) * 360',
               '0.65 + 0.35 * sin(2 * .pi * t / 4)']
    for marker in markers:
        require(marker in background, f'首页光晕/弧线/闪烁相位契约变化: {marker}')
    markers = ['TimelineView(.animation(minimumInterval: 0.05, paused: !ambientMotionActive))',
               'Self.orbitAngle(t, period: 90)', '-Self.orbitAngle(t, period: 60)',
               'Self.orbitAngle(t, period: 45)', '0.8 + 0.2 * sin(2 * .pi * t / 4)',
               '1.015 + 0.015 * sin(2 * .pi * t / 4)', 'ArcInscriptionText(text: captionText)',
               '.frame(width: 192, height: 192)']
    for marker in markers:
        require(marker in sphere, f'品牌球体/轨道/弧形文字契约变化: {marker}')
    source = (APP / 'Utils/DesignSystem.swift').read_text()
    for name, components in [('holoPrimary', '244/255, green: 109/255, blue: 56/255'),
                             ('holoPrimaryLight', '254/255, green: 215/255, blue: 170/255'),
                             ('holoPrimaryDark', '234/255, green: 88/255, blue: 12/255')]:
        require(f'static let {name} = Color(red: {components})' in source, f'品牌色变化: {name}')
    for dark, expected in ((False, 'FDFCF8'), (True, '0E0E10')):
        actual = ''.join(f'{round(channel * 255):02X}' for channel in rgb('Background', dark))
        require(actual == expected, f'首页背景色变化: {actual} != {expected}')
    return '品牌色、首页背景及球体/轨道/弧形文字/动画契约通过（非像素验收）'


def check_documentation():
    doc = (ROOT / 'docs/standards/设计规范.md').read_text()
    for name in ('ToolBackground', 'ToolSurface', 'ToolInset', 'ToolText', 'ToolTextSecondary',
                 'ToolBorder', 'ToolAction', 'ToolOnAction', 'ToolWarning', 'ToolSuccess',
                 'ToolError', 'ToolInfo', 'ToolAI'):
        row = next((line for line in doc.splitlines() if line.startswith(f'| holo{name} |')), '')
        require(bool(row), f'规范缺少业务色: {name}')
        expected = ['#' + ''.join(f'{round(channel * 255):02X}' for channel in rgb(name, dark)) for dark in (False, True)]
        actual = re.findall(r'#[0-9A-Fa-f]{6}', row)
        require(actual == expected, f'规范与资源漂移: {name} doc={actual} resource={expected}')
    return '13 个业务色的规范值与亮暗资源一致'


def main():
    checks = [('品牌隔离', check_brand), ('规范与资源', check_documentation)]
    for dark, label in ((False, 'Light'), (True, 'Dark')):
        checks.extend([(f'{label} 正文', lambda d=dark: check_text(d)),
                       (f'{label} 品牌动作', lambda d=dark: check_action(d))])
    failures = []
    for label, check in checks:
        try:
            print(f'PASS {label}: {check()}')
        except (AssertionError, ValueError, KeyError, StopIteration, OSError) as error:
            failures.append(label)
            print(f'FAIL {label}: {error}')
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())

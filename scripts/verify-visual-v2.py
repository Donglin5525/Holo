#!/usr/bin/env python3
"""验证 V2 的品牌隔离与实际资源对比度；不依赖模拟器或临时快照。"""
from pathlib import Path
import hashlib, json, re
ROOT = Path(__file__).resolve().parents[1]
CHECKS = [['Holo/Holo APP/Holo/Holo/Views/HomeView.swift', 'private var backgroundDecorations:', '.onAppear', 'd9e0ddfe2d99ecc264f3da727bb2aacfecb1a75e59b6e466ea45fbf139a2a2dc'], ['Holo/Holo APP/Holo/Holo/Components/DailyKanbanEntryButton.swift', 'private var sphere:', 'private var captionText:', 'fe15ee29d7f9454d4b44784acbb03d0195e68a7e4124982ae22b1cea24f60e72'], ['Holo/Holo APP/Holo/Holo/Components/DailyKanbanEntryButton.swift', 'private func progressOrbit(', '\x00', '1d6727a66be5216f0b886aa33667560c00227bb69705469c0434a2aa6b7b7358']]
for file, start, end, expected in CHECKS:
    text = (ROOT / file).read_text()
    block = text[text.index(start):] if end == "\0" else text[text.index(start):text.index(end, text.index(start))]
    assert hashlib.sha256(block.encode()).hexdigest() == expected, f"品牌绘制发生变化: {file}"
    assert "holoTool" not in block, f"工具色侵入品牌绘制: {file}"
source = (ROOT / 'Holo/Holo APP/Holo/Holo/Utils/DesignSystem.swift').read_text()
for declaration in ['static let holoPrimary = Color(red: 244/255, green: 109/255, blue: 56/255)  // #F46D38', 'static let holoPrimaryLight = Color(red: 254/255, green: 215/255, blue: 170/255)  // #FED7AA', 'static let holoPrimaryDark = Color(red: 234/255, green: 88/255, blue: 12/255)  // #EA580C', 'static let holoPurple = Color(red: 192/255, green: 132/255, blue: 252/255)  // #C084FC', 'static let holoInfo = Color(red: 96/255, green: 165/255, blue: 250/255)  // #60A5FA']:
    assert declaration in source, f"品牌色发生变化: {declaration}"
assert hashlib.sha256((ROOT / 'Holo/Holo APP/Holo/Holo/Assets.xcassets/Colors/Background.colorset/Contents.json').read_bytes()).hexdigest() == '08ce1823e86fdf1d8689f0484cc526bcf2ca2d2f682dc768a23693f82570cbb1', "首页背景色发生变化"

MOTION_CHECKS = [['Views/HomeView.swift', 'private var backgroundDecorations:', 'private func decorDot', [('.easeInOut(duration: 3.0).repeatForever(autoreverses: true)', 'orbDrift = 1.0'), ('.linear(duration: 60).repeatForever(autoreverses: false)', 'arcRotation = 360'), ('.easeInOut(duration: 2.0).repeatForever(autoreverses: true)', 'dotTwinkle = 0.3')]], ['Components/DailyKanbanEntryButton.swift', 'var body:', 'private var sphere:', [('.linear(duration: 90).repeatForever(autoreverses: false)', 'ringRotation1 = 360'), ('.linear(duration: 60).repeatForever(autoreverses: false)', 'ringRotation2 = -360'), ('.linear(duration: 45).repeatForever(autoreverses: false)', 'ringRotation3 = 360'), ('.easeInOut(duration: 2.0).repeatForever(autoreverses: true)', 'centerPulse = 1.0'), ('.easeInOut(duration: 2.0).repeatForever(autoreverses: true)', 'breathScale = 1.03')]]]
for file, start, end, expected in MOTION_CHECKS:
    text = (ROOT / "Holo/Holo APP/Holo/Holo" / file).read_text()
    block = text[text.index(start):text.index(end, text.index(start))]
    actual = re.findall(r'withAnimation\(([^\n]+repeatForever[^\n]+)\) \{\s*(\w+ = [^\n]+)', block)
    assert actual == expected, f"正常模式品牌运动参数发生变化: {file}"

def rgb(name, dark):
    resource = ROOT / 'Holo/Holo APP/Holo/Holo/Assets.xcassets/Colors' / f"{name}.colorset/Contents.json"
    entries = json.loads(resource.read_text())["colors"]
    entry = next(e for e in entries if bool(e.get("appearances")) == dark)
    c = entry["color"]["components"]
    return [float(c[k]) for k in ("red", "green", "blue")]

def luminance(values):
    linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in values]
    return sum(v * w for v, w in zip(linear, (0.2126, 0.7152, 0.0722)))

def contrast(fg, bg, dark):
    hi, lo = sorted([luminance(rgb(fg, dark)), luminance(rgb(bg, dark))], reverse=True)
    return (hi + .05) / (lo + .05)

# 2026-10-05 东林拍板「保结构、色值回品牌系」：正文/次文字维持 4.5:1（WCAG 普通文本）；
# 品牌橙作前景（橙色文字）与主按钮底色按 WCAG 大文本/非文本图形件标准 3:1（SC 1.4.3/1.4.11）。
for dark in (False, True):
    for foreground in ("ToolText", "ToolTextSecondary"):
        for background in ("ToolBackground", "ToolSurface", "ToolInset"):
            value = contrast(foreground, background, dark)
            assert value >= 4.5, f"文字对比度不足: {foreground}/{background} dark={dark} {value:.2f}"
    for background in ("ToolBackground", "ToolSurface", "ToolInset"):
        value = contrast("ToolAction", background, dark)
        assert value >= 3.0, f"品牌色前景对比度不足: {background} dark={dark} {value:.2f}"
    value = contrast("ToolOnAction", "ToolAction", dark)
    assert value >= 3.0, f"主按钮对比度不足: dark={dark} {value:.2f}"
    print(f"{'Dark' if dark else 'Light'}: 8 组文字≥4.5 + 4 组品牌色≥3.0 对比度通过")
print("品牌球体/轨道/弧形文字/背景/品牌色隔离通过")

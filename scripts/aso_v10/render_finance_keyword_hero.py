#!/usr/bin/env python3
"""按生产配置中的单屏关键词文案渲染真实统计截图草稿。"""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

EXPECTED = "3a2edfc5470d3842d9a93ebfb6d69313200757f0b1d0de3ec95c83ab66bef048"
MANIFEST = Path(__file__).parents[2] / "docs/_common/plans/2026-10-30-Holo-AppStore宣传图重设计/config/production-manifest.json"
FONT_MEDIUM = "/System/Library/Fonts/STHeiti Medium.ttc"
FONT_REGULAR = "/System/Library/Fonts/STHeiti Light.ttc"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--page-id", required=True, choices=["K02-A-01", "K02-B-01"])
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    page = next(x for x in manifest["pages"] if x["id"] == args.page_id)
    if page["raw_sources"] != ["R09"]:
        raise ValueError(f"{args.page_id} 当前仅允许使用R09")
    source_sha = hashlib.sha256(args.source.read_bytes()).hexdigest()
    if source_sha != EXPECTED:
        raise ValueError("R09哈希不匹配")
    with Image.open(args.source) as opened:
        opened.load()
        if opened.size != (1206, 2622):
            raise ValueError(f"R09尺寸不匹配: {opened.size}")
        source = opened.convert("RGB")

    canvas = Image.new("RGB", (1206, 2622), "#FDFCF8")
    draw = ImageDraw.Draw(canvas)
    def put(text, xy, size, path, color):
        face = ImageFont.truetype(path, size)
        if draw.textbbox(xy, text, font=face)[2] > xy[0] + 1062:
            raise ValueError(f"文案超出安全边距: {text}")
        draw.text(xy, text, font=face, fill=color)
    put("Holo", (72, 96), 32, FONT_MEDIUM, "#EA580C")
    put(page["title_lines"][0], (72, 204), 88, FONT_MEDIUM, "#333333")
    put(page["title_lines"][1], (72, 312), 88, FONT_MEDIUM, "#333333")
    put(page["subtitle"], (72, 458), 36, FONT_REGULAR, "#66605A")
    # 当前没有R09的无障碍sourceRect，因此完整屏幕放入HERO，不猜测裁切坐标。
    maxw, maxh = 858, 1865
    scale = min(maxw / source.width, maxh / source.height)
    w, h = round(source.width * scale), round(source.height * scale)
    screen = source.resize((w, h), Image.Resampling.LANCZOS)
    x, y = 174 + (maxw - w) // 2, 660 + (maxh - h) // 2
    canvas.paste(screen, (x, y))
    disclosure_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    disclosure_draw = ImageDraw.Draw(disclosure_layer)
    disclosure_draw.rounded_rectangle((72, 556, 350, 644), radius=28, fill="#B9380C")
    disclosure_draw.text((96, 580), "演示数据", font=ImageFont.truetype(FONT_MEDIUM, 38), fill="#FFFFFF")
    canvas = Image.alpha_composite(canvas.convert("RGBA"), disclosure_layer).convert("RGB")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(args.output, format="PNG")
    record = {
        "id": args.page_id, "configured_title": page["title_lines"],
        "configured_subtitle": page["subtitle"], "status": "draft_not_visual_reviewed_not_for_upload",
        "rendered_layout": "HERO", "layout_override_reason": "缺少R09 AX sourceRect，保留完整屏幕，避免估算裁切。",
        "canvas": [1206, 2622], "source_file": args.source.name,
        "source_sha256": source_sha, "source_rect": [0, 0, 1206, 2622],
        "destination_rect": [x, y, w, h], "demo_data": True,
        "disclosure": "演示数据",
        "disclosure_font_px": 38,
        "fonts": [FONT_MEDIUM, FONT_REGULAR],
        "output_sha256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
        "review_gates": ["视觉和缩略图检查待完成", "目标发布版本对照待完成", "App Store规格复核待完成"],
    }
    args.output.with_suffix(".json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(record, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

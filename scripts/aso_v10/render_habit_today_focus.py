#!/usr/bin/env python3
"""用R23今日习惯原图生成真实状态局部放大草稿。"""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

EXPECTED_R23_SHA = "a618dcb24c5f3120314298c05652d03937f793fe0ecfdb22337aa071f284337b"
FONT_MEDIUM = "/System/Library/Fonts/STHeiti Medium.ttc"
FONT_REGULAR = "/System/Library/Fonts/STHeiti Light.ttc"
MANIFEST = Path(__file__).parents[2] / "docs/_common/plans/2026-10-30-Holo-AppStore宣传图重设计/config/production-manifest.json"
CROP = (40, 160, 1166, 890)  # 左上含、右下不含像素边界


def paste_contain(canvas, image, box):
    x, y, width, height = box
    scale = min(width / image.width, height / image.height)
    w, h = round(image.width * scale), round(image.height * scale)
    resized = image.resize((w, h), Image.Resampling.LANCZOS)
    dest = (x + (width - w) // 2, y + (height - h) // 2)
    canvas.paste(resized, dest)
    return [*dest, w, h]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--page-id", required=True, choices=["K04-A-04", "K04-B-04"])
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    page = next(x for x in json.loads(MANIFEST.read_text())["pages"] if x["id"] == args.page_id)
    if page["raw_sources"] != ["R23"] or page["layout"] != "FOCUS":
        raise ValueError(f"{args.page_id}没有满足R23-only FOCUS合同")
    source_sha = hashlib.sha256(args.source.read_bytes()).hexdigest()
    if source_sha != EXPECTED_R23_SHA:
        raise ValueError("R23原图SHA-256不符")
    with Image.open(args.source) as opened:
        opened.load()
        if opened.size != (1206, 2622):
            raise ValueError(f"R23尺寸不符: {opened.size}")
        source = opened.convert("RGB")
    left, top, right, bottom = CROP
    if not (0 <= left < right <= source.width and 0 <= top < bottom <= source.height):
        raise ValueError("R23 sourceRect超出原图")
    focus = source.crop(CROP)

    canvas = Image.new("RGB", (1206, 2622), "#FDFCF8")
    draw = ImageDraw.Draw(canvas)
    def put(text, point, size, font_path, color):
        face = ImageFont.truetype(font_path, size)
        if draw.textbbox(point, text, font=face)[2] > point[0] + 1062:
            raise ValueError(f"文案超出安全范围: {text}")
        draw.text(point, text, font=face, fill=color)
    put("Holo", (72, 96), 32, FONT_MEDIUM, "#EA580C")
    put(page["title_lines"][0], (72, 204), 88, FONT_MEDIUM, "#333333")
    put(page["title_lines"][1], (72, 312), 88, FONT_MEDIUM, "#333333")
    put(page["subtitle"], (72, 458), 36, FONT_REGULAR, "#66605A")

    context_dest = paste_contain(canvas, source, (340, 660, 526, 1144))
    put("局部放大", (72, 1800), 30, FONT_REGULAR, "#66605A")
    focus_dest = paste_contain(canvas, focus, (72, 1850, 1062, 590))

    disclosure_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    disclosure = ImageDraw.Draw(disclosure_layer)
    disclosure.rounded_rectangle((72, 556, 350, 644), radius=28, fill="#B9380C")
    disclosure.text((96, 580), "演示数据", font=ImageFont.truetype(FONT_MEDIUM, 38), fill="#FFFFFF")
    canvas = Image.alpha_composite(canvas.convert("RGBA"), disclosure_layer).convert("RGB")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(args.output, format="PNG")
    report = {
        "id": args.page_id, "status": "draft_not_visual_reviewed_not_for_upload",
        "title_lines": page["title_lines"], "subtitle": page["subtitle"],
        "canvas": [1206, 2622], "source_file": args.source.name, "source_sha256": source_sha,
        "source_size": [1206, 2622], "source_rect_xywh": [left, top, right-left, bottom-top],
        "source_rect_bounds_ltrb": list(CROP), "context_destination": context_dest,
        "focus_destination": focus_dest, "focus_label": "局部放大",
        "disclosure": "演示数据", "disclosure_font_px": 38,
        "fonts": [FONT_MEDIUM, FONT_REGULAR], "demo_data": True,
        "output_sha256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
        "review_gates": ["焦点裁切和缩略可读性待复核", "正式版页面一致性待核对", "上架规格待复核"],
    }
    args.output.with_suffix(".json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

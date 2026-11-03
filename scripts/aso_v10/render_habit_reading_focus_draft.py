#!/usr/bin/env python3
"""从已审阅的 R22 中屏原图制作阅读累计 FOCUS 候选稿。"""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

EXPECTED_R22_SHA = "90eed698daad25c34f864dc1b5e8d34e8ccd7a01a7985dc7015a5a8458ba2cf5"
FONT_MEDIUM = "/System/Library/Fonts/STHeiti Medium.ttc"
FONT_REGULAR = "/System/Library/Fonts/STHeiti Light.ttc"
MANIFEST = Path(__file__).parents[2] / "docs/_common/plans/2026-10-30-Holo-AppStore宣传图重设计/config/production-manifest.json"
DEVICE = "iphone-medium"
FOCUS_SLOT = (72, 1550, 1062, 868)


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
    parser.add_argument("--page-id", required=True, choices=["K04-A-03", "K04-B-03"])
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    page = next(x for x in json.loads(MANIFEST.read_text())["pages"] if x["id"] == args.page_id)
    if page["raw_sources"] != ["R22"] or page["layout"] != "FOCUS":
        raise ValueError(f"{args.page_id}没有满足R22-only FOCUS合同")
    crop = page.get("source_rects_by_device", {}).get(DEVICE, {}).get("R22")
    context_crop = page.get("context_rects_by_device", {}).get(DEVICE, {}).get("R22")
    if not crop or len(crop) != 4 or not context_crop or len(context_crop) != 4:
        raise ValueError(f"{args.page_id}缺少{DEVICE}的实测R22 sourceRect")

    source_sha = hashlib.sha256(args.source.read_bytes()).hexdigest()
    if source_sha != EXPECTED_R22_SHA:
        raise ValueError("R22原图SHA-256不符")
    with Image.open(args.source) as opened:
        opened.load()
        if opened.size != (1206, 2622):
            raise ValueError(f"R22尺寸不符: {opened.size}")
        source = opened.convert("RGB")

    def source_crop(rect, name):
        x, y, width, height = rect
        if width <= 0 or height <= 0 or x < 0 or y < 0 or x + width > source.width or y + height > source.height:
            raise ValueError(f"R22 {name} sourceRect超出原图: {rect}")
        return source.crop((x, y, x + width, y + height))

    focus = source_crop(crop, "focus")
    context = source_crop(context_crop, "context")

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

    context_dest = paste_contain(canvas, context, (72, 690, 1062, 800))
    put("周期累计", (72, 1510), 30, FONT_REGULAR, "#66605A")
    focus_dest = paste_contain(canvas, focus, FOCUS_SLOT)

    disclosure_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    disclosure = ImageDraw.Draw(disclosure_layer)
    disclosure.rounded_rectangle((72, 556, 350, 644), radius=28, fill="#B9380C")
    disclosure.text((96, 580), "演示数据", font=ImageFont.truetype(FONT_MEDIUM, 38), fill="#FFFFFF")
    canvas = Image.alpha_composite(canvas.convert("RGBA"), disclosure_layer).convert("RGB")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(args.output, format="PNG")
    report = {
        "id": args.page_id,
        "status": "draft_not_visual_reviewed_not_for_upload",
        "device": DEVICE,
        "title_lines": page["title_lines"],
        "subtitle": page["subtitle"],
        "canvas": [1206, 2622],
        "source_file": args.source.name,
        "source_sha256": source_sha,
        "source_size": [1206, 2622],
        "context_source_rect_xywh": context_crop,
        "focus_source_rect_xywh": crop,
        "source_rect_convention": "left/top included; right/bottom excluded",
        "context_destination": context_dest,
        "context_slot": [72, 690, 1062, 800],
        "focus_destination": focus_dest,
        "focus_slot": list(FOCUS_SLOT),
        "focus_label": "周期累计",
        "disclosure": "演示数据",
        "disclosure_font_px": 38,
        "fonts": [FONT_MEDIUM, FONT_REGULAR],
        "demo_data": {"records": 18, "minutes": 600, "period": "2026-09-24..2026-10-30 inclusive"},
        "output_sha256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
        "review_gates": [
            "两个裁片的间距、真实关系和标题层级待目视复核",
            "6.9英寸iPhone和13英寸iPad须用原生设备截图并重新测量",
            "目标发布版本一致性待核对",
            "最终上架尺寸与缩略可读性待复核",
        ],
    }
    args.output.with_suffix(".json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

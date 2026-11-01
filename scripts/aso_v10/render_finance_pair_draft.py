#!/usr/bin/env python3
"""按页面配置生成财务月度对比草稿；不将输出视为可上架素材。"""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SOURCES = {
    "2026-08": ("holo-aso-v10-R10-finance-august.png", "7b97b7d73ac7f87d9bc4b2f45fed583d4cc8d0648eb071fe686946ba6438b630"),
    "2026-09": ("holo-aso-v10-R09-finance-september.png", "3a2edfc5470d3842d9a93ebfb6d69313200757f0b1d0de3ec95c83ab66bef048"),
}
FONT = "/System/Library/Fonts/STHeiti Medium.ttc"
REGULAR = "/System/Library/Fonts/STHeiti Light.ttc"
MANIFEST = Path(__file__).parents[2] / "docs/_common/plans/2026-10-30-Holo-AppStore宣传图重设计/config/production-manifest.json"


def font(path, size):
    if not Path(path).is_file():
        raise FileNotFoundError(f"需要可用中文字体: {path}")
    return ImageFont.truetype(path, size)


def text_fit(draw, text, xy, face, width, fill):
    bounds = draw.textbbox(xy, text, font=face)
    if bounds[2] > xy[0] + width:
        raise ValueError(f"文案超出安全范围: {text}")
    draw.text(xy, text, font=face, fill=fill)


def paste_contain(canvas, source, box):
    x, y, w, h = box
    scale = min(w / source.width, h / source.height)
    resized = source.resize((round(source.width * scale), round(source.height * scale)), Image.Resampling.LANCZOS)
    destination = (x + (w - resized.width) // 2, y + (h - resized.height) // 2)
    canvas.paste(resized, destination)
    return [*destination, resized.width, resized.height]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--page-id", choices=["K02-A-02", "K02-B-02"], default="K02-A-02")
    parser.add_argument("--sources", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    page = next(x for x in manifest["pages"] if x["id"] == args.page_id)
    images = {}
    for month, (name, expected) in SOURCES.items():
        path = args.sources / name
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected:
            raise ValueError(f"原图哈希不符: {path}")
        with Image.open(path) as image:
            image.load()
            if image.size != (1206, 2622):
                raise ValueError(f"原图尺寸不符: {path}: {image.size}")
            images[month] = image.convert("RGB")

    canvas = Image.new("RGB", (1206, 2622), "#FDFCF8")
    draw = ImageDraw.Draw(canvas)
    for content, xy, face, color in [
        ("Holo", (72, 96), font(FONT, 32), "#EA580C"),
        (page["title_lines"][0], (72, 204), font(FONT, 88), "#333333"),
        (page["title_lines"][1], (72, 312), font(FONT, 88), "#333333"),
        (page["subtitle"], (72, 458), font(REGULAR, 36), "#66605A"),
        ("2026 年 8 月", (66, 650), font(REGULAR, 32), "#66605A"),
        ("2026 年 9 月", (630, 1000), font(REGULAR, 32), "#66605A"),
        (page["external_overlay"], (96, 2300), font(FONT, 48), "#333333"),
    ]:
        text_fit(draw, content, xy, face, 1062 if xy[0] == 72 else 510 if xy[1] < 1100 else 1014, color)

    boxes = {
        "2026-08": paste_contain(canvas, images["2026-08"], (66, 700, 510, 1109)),
        "2026-09": paste_contain(canvas, images["2026-09"], (630, 1050, 510, 1109)),
    }
    disclosure_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    disclosure_draw = ImageDraw.Draw(disclosure_layer)
    disclosure_draw.rounded_rectangle((72, 556, 350, 644), radius=28, fill="#B9380C")
    disclosure_draw.text((96, 580), "演示数据", font=font(FONT, 38), fill="#FFFFFF")
    canvas = Image.alpha_composite(canvas.convert("RGBA"), disclosure_layer).convert("RGB")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(args.output, format="PNG")
    report = {
        "id": page["id"], "status": "draft_not_visual_reviewed_not_for_upload",
        "canvas": [1206, 2622], "font": [FONT, REGULAR], "source_sha256": {k: v[1] for k, v in SOURCES.items()},
        "source_destinations": boxes, "output_sha256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
        "disclosure": "演示数据",
        "disclosure_font_px": 38,
        "fact_line": page["external_overlay"],
        "warning": "开发候选未与目标发布版本核对；须完成视觉和上传规格验收。",
    }
    args.output.with_suffix(".json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

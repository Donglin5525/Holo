#!/usr/bin/env python3
"""按逐页配置、设备原图和已审阅 sourceRect 生成 App Store 候选图。"""
import argparse
import hashlib
import json
import math
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).parents[2]
PLAN = ROOT / "docs/_common/plans/2026-10-30-Holo-AppStore宣传图重设计"
DELIVERY = ROOT.parent / "Holo-ASO-交付草稿"
MANIFEST_PATH = PLAN / "config/production-manifest.json"
LAYOUTS_PATH = PLAN / "config/layouts.json"
FONT_MEDIUM = Path("/System/Library/Fonts/STHeiti Medium.ttc")
FONT_REGULAR = Path("/System/Library/Fonts/STHeiti Light.ttc")
COLORS = {
    "background": "#FDFCF8",
    "ink": "#333333",
    "secondary": "#66605A",
    "brand": "#EA580C",
    "disclosure": "#B9380C",
    "border": "#DED8D1",
}
DEVICE_SIZES = {
    "iphone-medium": (1206, 2622),
    "iphone-large": (1320, 2868),
    "ipad-13": (2064, 2752),
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_sources(device, raw_ids, source_variants=None):
    index_path = DELIVERY / "raw" / device / "raw-index.json"
    index = json.loads(index_path.read_text())
    captures = {}
    for item in index["captures"]:
        variant = item.get("source_variant", "default")
        captures.setdefault(item["capture_id"], {})[variant] = item
    variants = source_variants or {}
    sources = {}
    for raw_id in raw_ids:
        variant = variants.get(raw_id, "default")
        item = captures.get(raw_id, {}).get(variant)
        if not item:
            raise ValueError(f"{device} 缺少原始截图 {raw_id}（variant={variant}）")
        if item.get("visual_review") != "completed_read_only_review":
            raise ValueError(f"{raw_id} 尚未完成只读视觉复核")
        disposition = (item.get("disposition") or "").lower()
        blocked_markers = ("blocked", "rejected", "reference-only", "diagnostic only", "not usable")
        if any(marker in disposition for marker in blocked_markers):
            raise ValueError(f"{raw_id} 当前用途被来源台账限制：{item.get('disposition')}")
        if item.get("release_build_match") != "unverified":
            raise ValueError(f"{raw_id} 的版本映射字段无效；本轮只允许未映射的本地候选")
        path = index_path.parent / item["file"]
        if not path.is_file() or sha256(path) != item["sha256"]:
            raise ValueError(f"{raw_id} 原图缺失或 SHA-256 与索引不符")
        with Image.open(path) as opened:
            opened.load()
            expected = tuple(DEVICE_SIZES[device])
            if opened.size != expected:
                raise ValueError(f"{raw_id} 尺寸 {opened.size} 不符合 {device} 原生规格 {expected}")
            image = opened.convert("RGB")
        sources[raw_id] = {"image": image, "record": item, "path": path}
    return sources


def load_flow_input(page, device):
    config = page.get("input_asset_by_device", {}).get(device)
    if not config:
        raise ValueError(f"{page['id']} 缺少 {device} 的 FLOW 输入素材配置")
    path = DELIVERY / config["file"]
    if not path.is_file() or sha256(path) != config.get("sha256"):
        raise ValueError(f"{page['id']} FLOW 输入素材缺失或 SHA-256 与配置不符")
    with Image.open(path) as opened:
        opened.load()
        if list(opened.size) != config.get("pixel_size"):
            raise ValueError(f"{page['id']} FLOW 输入素材尺寸不符：{opened.size}")
        if opened.format != config.get("format"):
            raise ValueError(f"{page['id']} FLOW 输入素材格式不符：{opened.format}")
        return {"image": opened.convert("RGB"), "path": path, "config": config}


def fit_font(draw, text, font_path, preferred_size, min_size, max_width, max_height=None):
    for size in range(preferred_size, min_size - 1, -1):
        font = ImageFont.truetype(str(font_path), size)
        box = draw.textbbox((0, 0), text, font=font)
        if box[2] - box[0] <= max_width and (max_height is None or box[3] - box[1] <= max_height):
            return font
    raise ValueError(f"文案无法放入安全区域：{text}")


def put_text(draw, text, point, font_path, preferred_size, min_size, color, max_width, max_height=None):
    face = fit_font(draw, text, font_path, preferred_size, min_size, max_width, max_height)
    draw.text(point, text, font=face, fill=color)
    return face.size


def paste_contain(canvas, image, rect, scale):
    x, y, width, height = (round(v * scale) for v in rect)
    factor = min(width / image.width, height / image.height)
    out_width = max(1, round(image.width * factor))
    out_height = max(1, round(image.height * factor))
    resized = image.resize((out_width, out_height), Image.Resampling.LANCZOS)
    dx = x + (width - out_width) // 2
    dy = y + (height - out_height) // 2
    canvas.paste(resized, (dx, dy))
    ImageDraw.Draw(canvas).rectangle((dx, dy, dx + out_width - 1, dy + out_height - 1), outline=COLORS["border"], width=max(2, round(2 * scale)))
    return [dx, dy, out_width, out_height]


def checked_crop(image, rect, capture_id, name):
    if not rect or len(rect) != 4:
        raise ValueError(f"{capture_id} 缺少经过目视复核的 {name} sourceRect")
    x, y, width, height = rect
    if width <= 0 or height <= 0 or x < 0 or y < 0 or x + width > image.width or y + height > image.height:
        raise ValueError(f"{capture_id} 的 {name} sourceRect 越界：{rect}")
    return image.crop((x, y, x + width, y + height))


def create_canvas(device):
    width, height = DEVICE_SIZES[device]
    return Image.new("RGB", (width, height), COLORS["background"])


def device_scale(device):
    if device == "ipad-13":
        return 1.0
    return DEVICE_SIZES[device][0] / 1206


def header(canvas, page, device, scale):
    draw = ImageDraw.Draw(canvas)
    if device == "ipad-13":
        brand_rect = [96, 104, 1872, 64]
        title_rect = [96, 230, 1872, 232]
        subtitle_rect = [96, 478, 1872, 116]
        brand_size, title_size, subtitle_size = 42, 100, 42
    else:
        layouts = json.loads(LAYOUTS_PATH.read_text())
        brand_rect = layouts["header"]["brand_rect"]
        title_rect = layouts["header"]["title_rect"]
        subtitle_rect = layouts["header"]["subtitle_rect"]
        brand_size = round(32 * scale)
        title_size = round(88 * scale)
        subtitle_size = round(36 * scale)
    bx, by = round(brand_rect[0] * scale), round(brand_rect[1] * scale)
    put_text(draw, "Holo", (bx, by), FONT_MEDIUM, brand_size, round(28 * scale), COLORS["brand"], round(brand_rect[2] * scale), round(brand_rect[3] * scale))
    draw.rounded_rectangle((bx, by + round(52 * scale), bx + round(54 * scale), by + round(58 * scale)), radius=round(3 * scale), fill=COLORS["brand"])
    tx, ty, tw, th = (round(v * scale) for v in title_rect)
    lines = page.get("title_lines", [])
    if not 1 <= len(lines) <= 2:
        raise ValueError(f"{page['id']} 必须配置一到两行主标题")
    line_height = round((108 if device != "ipad-13" else 112) * scale)
    for i, line in enumerate(lines):
        put_text(draw, line, (tx, ty + i * line_height), FONT_MEDIUM, title_size, round((76 if device != "ipad-13" else 88) * scale), COLORS["ink"], tw, round(title_rect[3] * scale))
    sx, sy, sw, sh = (round(v * scale) for v in subtitle_rect)
    put_text(draw, page.get("subtitle", ""), (sx, sy), FONT_REGULAR, subtitle_size, round(28 * scale), COLORS["secondary"], sw, sh)
    # 所有当前原图来自本地虚构数据；角标置于 App 原图之外并保持高对比。
    badge_scale = scale
    if device == "ipad-13":
        badge_scale = 1.7
    badge = "演示数据"
    font_size = max(round(38 * badge_scale), 38)
    font = ImageFont.truetype(str(FONT_MEDIUM), font_size)
    text_box = draw.textbbox((0, 0), badge, font=font)
    badge_w = text_box[2] - text_box[0] + round(48 * badge_scale)
    badge_h = text_box[3] - text_box[1] + round(36 * badge_scale)
    badge_override = page.get("demo_disclosure_rect_by_device", {}).get(device)
    if badge_override:
        badge_x, badge_y, badge_w, badge_h = (round(v * scale) for v in badge_override)
    else:
        badge_x = round((1680 if device == "ipad-13" else 72) * scale)
        badge_y = round((104 if device == "ipad-13" else 556) * scale)
    draw.rounded_rectangle((badge_x, badge_y, badge_x + badge_w, badge_y + badge_h), radius=round(24 * badge_scale), fill=COLORS["disclosure"])
    draw.text((badge_x + round(20 * badge_scale), badge_y + round(14 * badge_scale)), badge, font=font, fill="#FFFFFF")
    return {"brand_rect": [bx, by, round(54 * scale), round(58 * scale)], "title_rect": [tx, ty, tw, th], "subtitle_rect": [sx, sy, sw, sh], "demo_badge_rect": [badge_x, badge_y, badge_w, badge_h], "demo_badge_text": badge, "demo_badge_font_px": font_size}


def render_hero(canvas, page, sources, device, scale):
    if len(page["raw_sources"]) != 1:
        raise ValueError(f"{page['id']} HERO 只接受一个原始页面")
    source_id = page["raw_sources"][0]
    box = page.get("layout_slots_by_device", {}).get(device, {}).get("primary")
    if box is None:
        box = [280, 640, 1504, 2005] if device == "ipad-13" else [174, 660, 858, 1865]
    source = sources[source_id]
    presentation_rect = source["record"].get("presentation_source_rect")
    image = checked_crop(source["image"], presentation_rect, source_id, "presentation") if presentation_rect else source["image"]
    return {source_id: paste_contain(canvas, image, box, scale)}


def month_label(capture):
    label = capture.get("capture_label")
    if label:
        return label
    fact = capture.get("evidence_fact", "")
    match = re.search(r"(20\d{2})-(0?[1-9]|1[0-2])", fact)
    if match:
        return f"{match.group(1)}年{int(match.group(2)):02d}月"
    return ""


def month_sort(source_id, capture):
    label = month_label(capture)
    return (label, source_id)


def render_pair(canvas, page, sources, device, scale):
    if len(page["raw_sources"]) != 2:
        raise ValueError(f"{page['id']} PAIR 必须有两张实际原图")
    if page.get("source_order_mode") == "configured":
        ordered = list(page["raw_sources"])
    else:
        ordered = sorted(page["raw_sources"], key=lambda rid: month_sort(rid, sources[rid]["record"]))
    slots = page.get("layout_slots_by_device", {}).get(device, {})
    default_primary = [96, 700, 900, 1200] if device == "ipad-13" else [66, 700, 510, 1109]
    default_secondary = [1068, 1080, 900, 1200] if device == "ipad-13" else [630, 1050, 510, 1109]
    primary_box = slots.get("primary", default_primary)
    secondary_box = slots.get("secondary", default_secondary)
    boxes = [primary_box, secondary_box]
    draw = ImageDraw.Draw(canvas)
    results = {}
    labels = {}
    for rid, box in zip(ordered, boxes):
        label = month_label(sources[rid]["record"])
        if not label:
            raise ValueError(f"{rid} 缺少能说明范围的原图标签")
        x, y, w, h = (round(v * scale) for v in box)
        put_text(draw, label, (x, y - round(52 * scale)), FONT_MEDIUM, round(32 * scale), round(26 * scale), COLORS["secondary"], w, round(44 * scale))
        source = sources[rid]
        presentation_rect = source["record"].get("presentation_source_rect")
        image = checked_crop(source["image"], presentation_rect, rid, "presentation") if presentation_rect else source["image"]
        results[rid] = paste_contain(canvas, image, box, scale)
        labels[rid] = label
    fact = page.get("external_overlay", "")
    if fact and fact != "演示数据":
        fact_box = [96, 2380, 1872, 200] if device == "ipad-13" else [72, 2260, 1062, 160]
        x, y, w, h = (round(v * scale) for v in fact_box)
        put_text(draw, fact, (x, y), FONT_MEDIUM, round(48 * scale), round(30 * scale), COLORS["ink"], w, h)
    return {"sources": results, "labels": labels, "fact_line": fact}


def focus_slots(page, device, scale):
    page_id = page["id"]
    configured_slots = page.get("layout_slots_by_device", {}).get(device)
    if configured_slots:
        return configured_slots
    if device == "ipad-13":
        if page_id in {"K04-A-03", "K04-B-03"}:
            return {"context": [96, 650, 1872, 570], "focus": [96, 1370, 1872, 1050], "caption": [96, 1260, 1872, 72]}
        if page_id in {"K04-A-04", "K04-B-04"}:
            return {"context": [532, 650, 1000, 1020], "focus": [600, 1760, 864, 970], "caption": [96, 1680, 1872, 72]}
        return {"context": [96, 640, 1872, 1200], "focus": [96, 1900, 1872, 650], "caption": [96, 1820, 1872, 60]}
    if page_id in {"K04-A-03", "K04-B-03"}:
        return {"context": [72, 690, 1062, 800], "focus": [72, 1550, 1062, 868], "caption": [72, 1482, 1062, 48]}
    if page_id in {"K04-A-04", "K04-B-04"}:
        # 大屏原图的弹层焦点较高，缩小完整页面上下文后为焦点区预留可见底边。
        return {"context": [340, 660, 526, 1080], "focus": [248, 1810, 710, 790], "caption": [72, 1750, 1062, 48]}
    return {"context": [340, 660, 526, 1144], "focus": [72, 1850, 1062, 590], "caption": [72, 1780, 1062, 48]}


def render_focus(canvas, page, sources, device, scale):
    if len(page["raw_sources"]) != 1:
        raise ValueError(f"{page['id']} FOCUS 只接受一个实际页面")
    source_id = page["raw_sources"][0]
    source = sources[source_id]["image"]
    record = sources[source_id]["record"]
    context_rect = record.get("context_source_rect")
    focus_rect = record.get("source_rect")
    if source_id == "R23" and not context_rect:
        # 未单独测量上下文框的设备以完整页面交代弹层来自哪里。
        context_image = source
    else:
        context_image = checked_crop(source, context_rect, source_id, "context")
    focus_image = checked_crop(source, focus_rect, source_id, "focus")
    slots = focus_slots(page, device, scale)
    context_dest = paste_contain(canvas, context_image, slots["context"], scale)
    draw = ImageDraw.Draw(canvas)
    caption_dest = [round(v * scale) for v in slots["caption"]]
    cap_x, cap_y, cap_w, cap_h = caption_dest
    caption = page.get("layout_caption_by_device", {}).get(device) or page.get("layout_caption") or ("今日记录 · 局部放大" if source_id == "R23" else "下图为本期每日记录量")
    put_text(draw, caption, (cap_x, cap_y), FONT_REGULAR, round(30 * scale), round(24 * scale), COLORS["secondary"], cap_w, cap_h)
    focus_dest = paste_contain(canvas, focus_image, slots["focus"], scale)
    measured_context_rect = context_rect or ([0, 0, source.width, source.height] if source_id == "R23" else None)
    coordinate_note = "native output pixels; slot_scale is 1.0" if device == "ipad-13" else "1206-based design grid units; multiply by slot_scale for output pixels"
    return {"source_id": source_id, "context_source_rect": measured_context_rect, "focus_source_rect": focus_rect, "context_destination": context_dest, "caption_destination_pixels": caption_dest, "focus_destination": focus_dest, "caption": caption, "slots": slots, "slot_coordinate_units": coordinate_note, "slot_scale": scale, "fit_note": "context/focus destination rectangles are the actual centered contain-fit pixel bounds and may be smaller than their slot boxes"}


def draw_arrow(draw, start, end, scale):
    """在App截图矩形外画流程箭头，不覆盖实际界面内容。"""
    x1, y1 = (round(value * scale) for value in start)
    x2, y2 = (round(value * scale) for value in end)
    color = COLORS["brand"]
    width = max(3, round(3 * scale))
    draw.line((x1, y1, x2, y2), fill=color, width=width)
    angle = math.atan2(y2 - y1, x2 - x1)
    length = round(14 * scale)
    wing = round(7 * scale)
    points = [
        (x2, y2),
        (round(x2 - length * math.cos(angle) + wing * math.sin(angle)), round(y2 - length * math.sin(angle) - wing * math.cos(angle))),
        (round(x2 - length * math.cos(angle) - wing * math.sin(angle)), round(y2 - length * math.sin(angle) + wing * math.cos(angle))),
    ]
    draw.polygon(points, fill=color)


def render_flow(canvas, page, sources, device, scale):
    """以真实输入素材和一张原生待确认页呈现图片录入后的核对步骤。"""
    if len(page["raw_sources"]) != 1:
        raise ValueError(f"{page['id']} FLOW 需要一张原生App待确认页")
    input_asset = load_flow_input(page, device)
    slots = page.get("layout_slots_by_device", {}).get(device, {})
    required_slots = {"input", "primary", "input_caption", "primary_caption"}
    if not required_slots.issubset(slots):
        missing = sorted(required_slots - set(slots))
        raise ValueError(f"{page['id']} FLOW 缺少版面槽位：{missing}")

    captions = page.get("flow_captions_by_device", {}).get(device, {})
    for key in ("input", "primary"):
        if not captions.get(key):
            raise ValueError(f"{page['id']} FLOW 缺少阶段标签：{key}")

    draw = ImageDraw.Draw(canvas)
    caption_rects = {}
    for key in ("input", "primary"):
        x, y, width, height = (round(value * scale) for value in slots[f"{key}_caption"])
        put_text(draw, captions[key], (x, y), FONT_MEDIUM, round(36 * scale), round(28 * scale), COLORS["secondary"], width, height)
        caption_rects[key] = [x, y, width, height]

    destinations = {
        "input": paste_contain(canvas, input_asset["image"], slots["input"], scale)
    }
    source_id = page["raw_sources"][0]
    record = sources[source_id]["record"]
    crop_rect = page.get("presentation_source_rect_overrides_by_device", {}).get(device, {}).get(source_id)
    crop_rect = crop_rect or record.get("presentation_source_rect")
    stage_image = checked_crop(sources[source_id]["image"], crop_rect, source_id, "presentation")
    destinations["primary"] = paste_contain(canvas, stage_image, slots["primary"], scale)

    input_box = slots["input"]
    primary_box = slots["primary"]
    # 按页面槽位关系决定箭头方向，箭头始终留在两块素材之外。
    if input_box[1] + input_box[3] <= primary_box[1]:
        arrow_start = (primary_box[0] + primary_box[2] / 2, input_box[1] + input_box[3] + 8)
        arrow_end = (primary_box[0] + primary_box[2] / 2, primary_box[1] - 8)
    elif input_box[0] + input_box[2] <= primary_box[0]:
        arrow_start = (input_box[0] + input_box[2] + 8, input_box[1] + input_box[3] / 2)
        arrow_end = (primary_box[0] - 10, primary_box[1] + primary_box[3] / 2)
    else:
        raise ValueError(f"{page['id']} FLOW 输入和结果槽位没有可放置箭头的间隔")
    draw_arrow(draw, arrow_start, arrow_end, scale)
    return {
        "input_asset": {"file": input_asset["path"].name, "sha256": input_asset["config"]["sha256"], "pixel_size": input_asset["config"]["pixel_size"], "format": input_asset["config"]["format"]},
        "stage_source_id": source_id,
        "stage_source_rect": crop_rect,
        "caption_text": captions,
        "caption_rects": caption_rects,
        "destinations": destinations,
        "slots": slots,
        "slot_coordinate_units": "native output pixels" if device == "ipad-13" else "1206-based design grid units; multiply by slot_scale for output pixels",
        "slot_scale": scale,
        "fit_note": "演示输入素材和一张App原生待确认页均等比contain；箭头在两者矩形外。已入账结果由后续独立页面呈现，避免重复放大同一笔金额。",
    }


def load_export_asset(page, device):
    asset = page.get("export_asset_by_device", {}).get(device)
    if not asset:
        raise ValueError(f"{page['id']} 缺少 {device} 的 App 实际导出文件配置")
    path = DELIVERY / asset["file"]
    if not path.is_file() or sha256(path) != asset.get("sha256"):
        raise ValueError(f"{page['id']} 实际导出文件缺失或 SHA-256 与索引不符")
    with Image.open(path) as opened:
        opened.load()
        if list(opened.size) != asset.get("pixel_size"):
            raise ValueError(f"{page['id']} 实际导出尺寸与配置不符：{opened.size}")
        if opened.format != asset.get("format"):
            raise ValueError(f"{page['id']} 实际导出格式与配置不符：{opened.format}")
        image = opened.convert("RGB")
    return {"image": image, "path": path, "asset": asset}


def render_journal(canvas, page, sources, device, scale):
    if len(page["raw_sources"]) != 1:
        raise ValueError(f"{page['id']} JOURNAL 必须配置一张 Holo 原生上下文截图")
    slots = page.get("layout_slots_by_device", {}).get(device)
    required_slots = {"context", "export", "context_caption", "export_caption"}
    if not slots or not required_slots.issubset(slots):
        raise ValueError(f"{page['id']} 缺少 {device} JOURNAL 布局槽：{sorted(required_slots)}")

    source_id = page["raw_sources"][0]
    source = sources[source_id]
    record = source["record"]
    context_rect = page.get("context_source_rect_by_device", {}).get(device) or record.get("presentation_source_rect") or record.get("context_source_rect")
    context_image = checked_crop(source["image"], context_rect, source_id, "presentation") if context_rect else source["image"]
    export = load_export_asset(page, device)

    context_destination = paste_contain(canvas, context_image, slots["context"], scale)
    export_destination = paste_contain(canvas, export["image"], slots["export"], scale)
    draw = ImageDraw.Draw(canvas)
    captions = {
        "context_caption": page.get("context_caption_by_device", {}).get(device, page.get("context_caption", "Holo 原生分享界面")),
        "export_caption": page.get("export_caption_by_device", {}).get(device, page.get("export_caption", "同一演示记录 · App 实际导出")),
    }
    caption_destinations = {}
    for key, caption in captions.items():
        x, y, width, height = (round(v * scale) for v in slots[key])
        put_text(draw, caption, (x, y), FONT_MEDIUM, round(30 * scale), round(23 * scale), COLORS["secondary"], width, height)
        caption_destinations[key] = [x, y, width, height]
    return {
        "source_id": source_id,
        "context_source_rect": context_rect or [0, 0, source["image"].width, source["image"].height],
        "context_destination": context_destination,
        "export_asset": {"file": str(export["path"]), "sha256": export["asset"]["sha256"], "pixel_size": export["asset"]["pixel_size"], "format": export["asset"]["format"]},
        "export_destination": export_destination,
        "captions": captions,
        "caption_destinations": caption_destinations,
        "slots": slots,
        "slot_coordinate_units": "native output pixels" if device == "ipad-13" else "1206-based design grid units; multiply by slot_scale for output pixels",
        "slot_scale": scale,
        "fit_note": "两个素材均等比完整呈现；上方为Holo原生上下文截图，下方为同一设备中实际生成的JPEG导出文件。外层标签不覆盖原图。",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--page-id", required=True)
    parser.add_argument("--device", required=True, choices=sorted(DEVICE_SIZES))
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not FONT_MEDIUM.is_file() or not FONT_REGULAR.is_file():
        raise FileNotFoundError("找不到已核对的中文字体 STHeiti")
    manifest = json.loads(MANIFEST_PATH.read_text())
    layouts = json.loads(LAYOUTS_PATH.read_text())
    page = next((item for item in manifest["pages"] if item["id"] == args.page_id), None)
    if page is None:
        raise ValueError(f"production-manifest 中没有 {args.page_id}")
    if page.get("status") == "blocked_source_quality":
        raise ValueError(f"{args.page_id} 因来源质量被阻塞，不能生成候选")
    page = dict(page)
    device_sources = page.get("raw_sources_by_device", {}).get(args.device)
    if device_sources is not None:
        page["raw_sources"] = device_sources
    layout = page.get("layout_by_device", {}).get(args.device, page.get("layout"))
    if layout not in {"HERO", "FOCUS", "FLOW", "PAIR", "JOURNAL"}:
        raise ValueError(f"当前候选渲染器不支持布局 {layout}")
    source_variants = dict(page.get("source_variants", {}))
    source_variants.update(page.get("source_variants_by_device", {}).get(args.device, {}))
    sources = load_sources(args.device, page["raw_sources"], source_variants)
    canvas = create_canvas(args.device)
    scale = device_scale(args.device)
    header_record = header(canvas, page, args.device, scale)
    if layout == "HERO":
        placement = render_hero(canvas, page, sources, args.device, scale)
    elif layout == "PAIR":
        placement = render_pair(canvas, page, sources, args.device, scale)
    elif layout == "FLOW":
        placement = render_flow(canvas, page, sources, args.device, scale)
    elif layout == "JOURNAL":
        placement = render_journal(canvas, page, sources, args.device, scale)
    else:
        placement = render_focus(canvas, page, sources, args.device, scale)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(args.output, format="PNG", optimize=True)
    size = list(DEVICE_SIZES[args.device])
    report = {
        "page_id": page["id"], "series_id": page["series_id"], "device": args.device,
        "output": str(args.output), "output_size": size, "output_mode": "RGB",
        "coordinate_system": {
            "configured_layout_slots": "native output pixels" if args.device == "ipad-13" else "1206-based design grid units",
            "placement_destinations": "output pixels",
            "slot_scale_to_output_pixels": scale,
        },
        "output_sha256": sha256(args.output), "title_lines": page["title_lines"],
        "subtitle": page["subtitle"], "layout": layout,
        "accent": page.get("accent"), "demo_disclosure": header_record["demo_badge_text"],
        "demo_disclosure_rect": header_record["demo_badge_rect"],
        "sources": {rid: {"file": sources[rid]["path"].name, "variant": sources[rid]["record"].get("source_variant", "default"), "sha256": sources[rid]["record"]["sha256"], "pixel_size": sources[rid]["record"]["pixel_size"], "visual_review": sources[rid]["record"]["visual_review"], "release_build_match": sources[rid]["record"]["release_build_match"], "presentation_source_rect": sources[rid]["record"].get("presentation_source_rect")} for rid in page["raw_sources"]},
        "external_input_asset": placement.get("input_asset"),
        "placement": placement,
        "claim": {"benefit": page.get("benefit"), "semantic_focus": page.get("semantic_focus"), "external_overlay": page.get("external_overlay")},
        "status": "draft_visual_review_pending_release_mapping_unverified_not_for_upload",
        "release_mapping_status": "unverified",
        "source_rect_bounds_convention": "left/top included; right/bottom excluded",
        "review_gates": ["独立只读视觉复核", "缩略图可读性", "发布版本匹配", "App Store 上传规格", "所有文案与数据事实复核"],
    }
    report_path = args.output.with_suffix(".json")
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

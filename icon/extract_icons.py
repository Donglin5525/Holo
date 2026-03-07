#!/usr/bin/env python3
"""
从 Figma 导出的复合 SVG 中提取 71 个独立分类图标，
生成独立 SVG 文件并创建 Xcode imageset 目录结构。
"""
import re
import os
import json

# --- 路径配置 ---
SVG_PATH = "/Users/tangyuxuan/Desktop/cursor/HOLO/icon/科目图标.svg"
OUTPUT_DIR = "/Users/tangyuxuan/Desktop/cursor/HOLO/icon/svg"
ASSETS_DIR = "/Users/tangyuxuan/Desktop/cursor/HOLO/Holo/Holo APP/Holo/Holo/Assets.xcassets/CategoryIcons"

# --- 图标命名映射（按 SVG 中视觉位置排序：先上下再左右）---
ICON_NAMES = [
    # ========== 支出 (55 icons, indices 0-54) ==========
    # 餐饮 Dining (#13A4EC, 7)
    "icon_breakfast", "icon_lunch", "icon_dinner", "icon_late_snack",
    "icon_snack", "icon_coffee", "icon_takeout",
    # 购物 Shopping (#F97316, 8)
    "icon_clothes", "icon_digital", "icon_groceries", "icon_beauty",
    "icon_furniture", "icon_book", "icon_sport", "icon_present",
    # 居住 Housing (#6366F1, 6)
    "icon_rent", "icon_water", "icon_electricity", "icon_gas",
    "icon_property", "icon_internet",
    # 交通 Transport (#10B981, 7)
    "icon_metro", "icon_taxi", "icon_bike_share", "icon_fuel",
    "icon_parking", "icon_travel", "icon_toll",
    # 娱乐 Entertainment (#EC4899, 7)
    "icon_cinema", "icon_gaming", "icon_video", "icon_music",
    "icon_ktv", "icon_trip", "icon_fitness",
    # 医疗 Health (#F43F5E, 5)
    "icon_medical", "icon_medicine", "icon_checkup", "icon_gym",
    "icon_supplement",
    # 学习 Learning (#06B6D4, 5)
    "icon_course", "icon_textbook", "icon_exam", "icon_stationery",
    "icon_subscription",
    # 其他支出 Other Expenses (#64748B, 10)
    "icon_social", "icon_pet", "icon_barber", "icon_laundry",
    "icon_repair", "icon_insurance", "icon_repayment", "icon_transfer_out",
    "icon_donation", "icon_other_exp",
    # ========== 收入 (16 icons, indices 55-70) ==========
    # Row 18: 工资(绿)+投资(蓝) 交替排列
    "icon_salary", "icon_bonus", "icon_interest", "icon_stock",
    # Row 19: 兼职(绿)+投资续(蓝)
    "icon_parttime", "icon_refund", "icon_rent_income", "icon_invest_other",
    # Row 20: 其他收入A(红)+其他收入B(紫)
    "icon_red_packet", "icon_gift", "icon_loan_in", "icon_repay_in",
    # Row 21: 其他收入A续(红)+其他收入B续(紫)
    "icon_winning", "icon_transfer_in", "icon_return", "icon_other_inc",
]

# --- 各分类的设计色 ---
CATEGORY_COLORS = {
    "icon_breakfast": "#13A4EC", "icon_lunch": "#13A4EC", "icon_dinner": "#13A4EC",
    "icon_late_snack": "#13A4EC", "icon_snack": "#13A4EC", "icon_coffee": "#13A4EC",
    "icon_takeout": "#13A4EC",
    "icon_clothes": "#F97316", "icon_digital": "#F97316", "icon_groceries": "#F97316",
    "icon_beauty": "#F97316", "icon_furniture": "#F97316", "icon_book": "#F97316",
    "icon_sport": "#F97316", "icon_present": "#F97316",
}


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    with open(SVG_PATH, "r") as f:
        content = f.read()

    # --- Step 1: 找到所有图标背景 (56×56 圆角矩形) ---
    bg_pat = (
        r'<rect\s+x="([\d.]+)"\s+y="([\d.]+)"\s+'
        r'width="56"\s+height="56"\s+rx="16"\s+'
        r'fill="(#[0-9A-Fa-f]+)"\s+fill-opacity="0\.1"\s*/>'
    )
    backgrounds = []
    for m in re.finditer(bg_pat, content):
        backgrounds.append({
            "start": m.start(),
            "end": m.end(),
            "x": float(m.group(1)),
            "y": float(m.group(2)),
            "color": m.group(3),
        })
    backgrounds.sort(key=lambda b: (b["y"], b["x"]))
    print(f"找到 {len(backgrounds)} 个图标背景")

    if len(backgrounds) != len(ICON_NAMES):
        print(f"警告: 背景数 ({len(backgrounds)}) != 命名数 ({len(ICON_NAMES)})")
        return

    # --- Step 2: 提取每个图标的路径数据 ---
    icons = []
    for i, bg in enumerate(backgrounds):
        search_start = bg["end"]
        search_end = backgrounds[i + 1]["start"] if i + 1 < len(backgrounds) else len(content)
        section = content[search_start:search_end]

        color_esc = re.escape(bg["color"])

        # 匹配所有与图标颜色相同的 <path> 元素
        path_pat = r'<path\s+([^>]*?fill="' + color_esc + r'"[^>]*?)\s*/>'
        alt_pat = r'<path\s+([^>]*?)fill="' + color_esc + r'"([^>]*?)\s*/>'

        raw_paths = []
        for pm in re.finditer(alt_pat, section):
            attrs_text = pm.group(1) + 'fill="' + bg["color"] + '"' + pm.group(2)
            d_m = re.search(r'd="([^"]+)"', attrs_text)
            if not d_m:
                continue
            d_val = d_m.group(1)
            fr_m = re.search(r'fill-rule="([^"]+)"', attrs_text)
            cr_m = re.search(r'clip-rule="([^"]+)"', attrs_text)
            raw_paths.append({
                "d": d_val,
                "fill_rule": fr_m.group(1) if fr_m else None,
                "clip_rule": cr_m.group(1) if cr_m else None,
            })

        # 同时查找 <circle> 元素
        circle_pat = r'<circle\s+([^>]*?fill="' + color_esc + r'"[^>]*?)\s*/>'
        circles = list(re.finditer(circle_pat, section))

        # 同时查找 <rect> 元素（排除背景矩形）
        rect_pat = r'<rect\s+([^>]*?fill="' + color_esc + r'"[^>]*?)\s*/>'
        rects = []
        for rm in re.finditer(rect_pat, section):
            if 'fill-opacity="0.1"' not in rm.group(0):
                rects.append(rm)

        icons.append({
            "name": ICON_NAMES[i],
            "x": bg["x"],
            "y": bg["y"],
            "color": bg["color"],
            "paths": raw_paths,
            "circles": [c.group(0) for c in circles],
            "extra_rects": [r.group(0) for r in rects],
        })

    # --- Step 3: 生成独立 SVG + Xcode imageset ---
    created = 0
    for icon in icons:
        name = icon["name"]
        vb_x, vb_y = icon["x"], icon["y"]
        color = icon["color"]

        # 构建 SVG
        svg_lines = [
            f'<svg preserveAspectRatio="none" width="100%" height="100%" '
            f'overflow="visible" style="display: block;" '
            f'viewBox="{vb_x} {vb_y} 56 56" fill="none" '
            f'xmlns="http://www.w3.org/2000/svg">',
            '<g id="Container">',
        ]

        for j, p in enumerate(icon["paths"]):
            attrs = f'd="{p["d"]}"'
            if p["fill_rule"]:
                attrs += f' fill-rule="{p["fill_rule"]}"'
            if p["clip_rule"]:
                attrs += f' clip-rule="{p["clip_rule"]}"'
            attrs += f' fill="var(--fill-0, {color})"'
            svg_lines.append(f'<path id="Icon{"" if j == 0 else j}" {attrs}/>')

        for el in icon["circles"]:
            svg_lines.append(el.replace(f'fill="{color}"', f'fill="var(--fill-0, {color})"'))
        for el in icon["extra_rects"]:
            svg_lines.append(el.replace(f'fill="{color}"', f'fill="var(--fill-0, {color})"'))

        svg_lines.append("</g>")
        svg_lines.append("</svg>")
        svg_content = "\n".join(svg_lines) + "\n"

        # 保存到 icon/svg/ 目录
        svg_file = os.path.join(OUTPUT_DIR, f"{name}.svg")
        with open(svg_file, "w") as f:
            f.write(svg_content)

        # 创建 Xcode imageset
        imageset_dir = os.path.join(ASSETS_DIR, f"{name}.imageset")
        os.makedirs(imageset_dir, exist_ok=True)

        with open(os.path.join(imageset_dir, f"{name}.svg"), "w") as f:
            f.write(svg_content)

        contents_json = {
            "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {
                "preserves-vector-representation": True,
                "template-rendering-intent": "template",
            },
        }
        with open(os.path.join(imageset_dir, "Contents.json"), "w") as f:
            json.dump(contents_json, f, indent=2)
            f.write("\n")

        created += 1
        path_count = len(icon["paths"])
        extra = len(icon["circles"]) + len(icon["extra_rects"])
        print(f"  ✓ {name:25s}  ({icon['x']:>7.2f}, {icon['y']:>7.2f})  "
              f"paths={path_count}  extras={extra}  color={color}")

    print(f"\n完成: 创建了 {created} 个图标 imageset")
    print(f"  SVG 目录: {OUTPUT_DIR}")
    print(f"  Assets 目录: {ASSETS_DIR}")


if __name__ == "__main__":
    main()

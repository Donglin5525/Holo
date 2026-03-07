#!/usr/bin/env python3
"""
将 Figma 导出的 71 个 Container SVG 文件转换为 Xcode Asset Catalog imageset。

处理流程:
1. 读取每个 Container-N.svg
2. 提取图标形状路径（移除背景矩形和文字标签）
3. 生成适配 Xcode 模板渲染的干净 SVG
4. 创建 imageset 目录结构
"""
import re
import os
import json

# --- 路径配置 ---
ICON_DIR = "/Users/tangyuxuan/Desktop/cursor/HOLO/icon/Finance icon"
ASSETS_DIR = "/Users/tangyuxuan/Desktop/cursor/HOLO/Holo/Holo APP/Holo/Holo/Assets.xcassets/CategoryIcons"

# --- Container 编号 → 图标名称映射 ---
# 基于 Figma 导出顺序 + 复合 SVG 位置分析
CONTAINER_MAP = {
    # ===== 收入 - 投资理财 (#3B82F6, Container 0-3) =====
    0: "icon_interest",       # 利息
    1: "icon_stock",          # 股票
    2: "icon_rent_income",    # 房租收入
    3: "icon_invest_other",   # 其他投资
    # ===== 收入 - 工资/兼职 (#22C55E, Container 4-7) =====
    4: "icon_salary",         # 工资
    5: "icon_bonus",          # 奖金
    6: "icon_parttime",       # 兼职
    7: "icon_refund",         # 退款
    # ===== 支出 - 医疗 (#F43F5E, Container 8-12) =====
    8: "icon_medical",        # 就医
    9: "icon_medicine",       # 药品
    10: "icon_checkup",       # 体检
    11: "icon_gym",           # 健身房
    12: "icon_supplement",    # 保健品
    # ===== 支出 - 其他支出 (#64748B, Container 13-22) =====
    13: "icon_social",        # 社交
    14: "icon_pet",           # 宠物
    15: "icon_barber",        # 理发
    16: "icon_laundry",       # 洗衣
    17: "icon_repair",        # 维修
    18: "icon_insurance",     # 保险
    19: "icon_repayment",     # 还款
    20: "icon_transfer_out",  # 转账
    21: "icon_donation",      # 捐赠
    22: "icon_other_exp",     # 其他支出
    # ===== 支出 - 交通 (#10B981, Container 23-29) =====
    23: "icon_metro",         # 地铁/公交
    24: "icon_taxi",          # 打车
    25: "icon_bike_share",    # 共享单车
    26: "icon_fuel",          # 加油
    27: "icon_parking",       # 停车
    28: "icon_travel",        # 旅行
    29: "icon_toll",          # 过路费
    # ===== 收入 - 其他收入A (#EF4444, Container 30-33) =====
    30: "icon_red_packet",    # 红包
    31: "icon_gift",          # 礼物
    32: "icon_winning",       # 中奖
    33: "icon_transfer_in",   # 转入
    # ===== 支出 - 娱乐 (#EC4899, Container 34-40) =====
    34: "icon_cinema",        # 电影
    35: "icon_gaming",        # 游戏
    36: "icon_video",         # 视频
    37: "icon_music",         # 音乐
    38: "icon_ktv",           # KTV
    39: "icon_trip",          # 旅游
    40: "icon_fitness",       # 健身
    # ===== 收入 - 其他收入B (#A855F7, Container 41-44) =====
    41: "icon_loan_in",       # 借入
    42: "icon_repay_in",      # 还款收入
    43: "icon_return",        # 退货
    44: "icon_other_inc",     # 其他收入
    # ===== 支出 - 学习 (#06B6D4, Container 45-49) =====
    45: "icon_course",        # 课程
    46: "icon_textbook",      # 书籍
    47: "icon_exam",          # 考试
    48: "icon_stationery",    # 文具
    49: "icon_subscription",  # 订阅
    # ===== 支出 - 居住 (#6366F1, Container 50-55) =====
    50: "icon_rent",          # 房租
    51: "icon_water",         # 水费
    52: "icon_electricity",   # 电费
    53: "icon_gas",           # 燃气
    54: "icon_property",      # 物业
    55: "icon_internet",      # 网费
    # ===== 支出 - 购物 (#F97316, Container 56-63) =====
    56: "icon_clothes",       # 服饰
    57: "icon_digital",       # 数码
    58: "icon_groceries",     # 日用
    59: "icon_beauty",        # 美妆
    60: "icon_furniture",     # 家具
    61: "icon_book",          # 书籍
    62: "icon_sport",         # 运动
    63: "icon_present",       # 礼物
    # ===== 支出 - 餐饮 (#13A4EC, Container 64-70) =====
    64: "icon_breakfast",     # 早餐
    65: "icon_lunch",         # 午餐
    66: "icon_dinner",        # 晚餐
    67: "icon_late_snack",    # 夜宵
    68: "icon_snack",         # 零食
    69: "icon_coffee",        # 咖啡
    70: "icon_takeout",       # 外卖
}

# 文字标签色（需要移除的路径）
TEXT_COLORS = {"#475569", "#0F172A"}


def get_container_filename(num):
    """根据编号获取文件名"""
    if num == 0:
        return "Container.svg"
    return f"Container-{num}.svg"


def extract_icon_from_container(filepath):
    """
    从 Container SVG 中提取图标信息。
    Returns: (bg_x, bg_y, bg_color, icon_fill_color, icon_paths_raw)
    """
    with open(filepath, "r") as f:
        content = f.read()

    # 提取背景矩形位置和颜色
    bg_match = re.search(
        r'<rect\s+x="([\d.]+)"\s+(?:y="([\d.]+)")?\s*'
        r'width="56"\s+height="56"\s+rx="16"\s+'
        r'fill="(#[0-9A-Fa-f]+)"\s+fill-opacity="0\.1"',
        content,
    )
    if not bg_match:
        return None

    bg_x = float(bg_match.group(1))
    bg_y = float(bg_match.group(2)) if bg_match.group(2) else 0.0
    bg_color = bg_match.group(3)

    # 提取所有 <path> 元素
    all_paths = re.finditer(r"<path\s+([^>]+?)/>", content)

    icon_paths = []
    icon_fill = None
    for pm in all_paths:
        attrs = pm.group(1)
        # 提取 fill 颜色
        fill_match = re.search(r'fill="(#[0-9A-Fa-f]+)"', attrs)
        if not fill_match:
            continue
        fill_color = fill_match.group(1)

        # 跳过文字标签路径
        if fill_color in TEXT_COLORS:
            continue

        # 提取 d 属性
        d_match = re.search(r'd="([^"]+)"', attrs)
        if not d_match:
            continue

        icon_fill = fill_color
        path_attrs = f'd="{d_match.group(1)}"'

        # 保留 fill-rule / clip-rule
        fr = re.search(r'fill-rule="([^"]+)"', attrs)
        cr = re.search(r'clip-rule="([^"]+)"', attrs)
        if fr:
            path_attrs += f' fill-rule="{fr.group(1)}"'
        if cr:
            path_attrs += f' clip-rule="{cr.group(1)}"'

        icon_paths.append(path_attrs)

    return bg_x, bg_y, bg_color, icon_fill, icon_paths


def create_icon_svg(bg_x, bg_y, icon_fill, icon_paths):
    """生成干净的独立图标 SVG（适配 Xcode 模板渲染）"""
    lines = [
        f'<svg preserveAspectRatio="none" width="100%" height="100%" '
        f'overflow="visible" style="display: block;" '
        f'viewBox="{bg_x} {bg_y} 56 56" fill="none" '
        f'xmlns="http://www.w3.org/2000/svg">',
        '<g id="Container">',
    ]

    for i, attrs in enumerate(icon_paths):
        tag_id = "Icon" if i == 0 else f"Icon{i}"
        lines.append(f'<path id="{tag_id}" {attrs} fill="var(--fill-0, {icon_fill})"/>')

    lines.append("</g>")
    lines.append("</svg>")
    return "\n".join(lines) + "\n"


def create_imageset(name, svg_content, assets_dir):
    """创建 Xcode imageset 目录和文件"""
    imageset_dir = os.path.join(assets_dir, f"{name}.imageset")
    os.makedirs(imageset_dir, exist_ok=True)

    # 写入 SVG
    svg_path = os.path.join(imageset_dir, f"{name}.svg")
    with open(svg_path, "w") as f:
        f.write(svg_content)

    # 写入 Contents.json
    contents = {
        "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {
            "preserves-vector-representation": True,
            "template-rendering-intent": "template",
        },
    }
    contents_path = os.path.join(imageset_dir, "Contents.json")
    with open(contents_path, "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")


def main():
    os.makedirs(ASSETS_DIR, exist_ok=True)

    created = 0
    skipped = 0
    errors = 0

    for num in sorted(CONTAINER_MAP.keys()):
        name = CONTAINER_MAP[num]
        filename = get_container_filename(num)
        filepath = os.path.join(ICON_DIR, filename)

        if not os.path.exists(filepath):
            print(f"  ✗ {name:25s}  文件不存在: {filename}")
            errors += 1
            continue

        result = extract_icon_from_container(filepath)
        if result is None:
            print(f"  ✗ {name:25s}  无法解析: {filename}")
            errors += 1
            continue

        bg_x, bg_y, bg_color, icon_fill, icon_paths = result

        if not icon_paths:
            print(f"  ⚠ {name:25s}  未找到图标路径: {filename}  bg={bg_color}")
            skipped += 1
            continue

        svg_content = create_icon_svg(bg_x, bg_y, icon_fill, icon_paths)
        create_imageset(name, svg_content, ASSETS_DIR)

        created += 1
        print(
            f"  ✓ {name:25s}  ← {filename:20s}  "
            f"bg={bg_color}  fill={icon_fill}  paths={len(icon_paths)}"
        )

    print(f"\n{'='*60}")
    print(f"完成: 创建 {created} 个 imageset, 跳过 {skipped}, 错误 {errors}")
    print(f"Assets 目录: {ASSETS_DIR}")

    # 列出该目录下已有的 imageset
    existing = [
        d for d in os.listdir(ASSETS_DIR)
        if d.endswith(".imageset") and os.path.isdir(os.path.join(ASSETS_DIR, d))
    ]
    print(f"CategoryIcons 目录中共有 {len(existing)} 个 imageset")


if __name__ == "__main__":
    main()

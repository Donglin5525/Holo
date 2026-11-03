#!/usr/bin/env python3
"""按已核验的套图顺序生成静态ASO评审画廊。"""

from __future__ import annotations

import hashlib
import html
import json
import struct
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLAN = ROOT / "docs/_common/plans/2026-10-30-Holo-AppStore宣传图重设计"
ASSETS = ROOT.parent / "Holo-ASO-交付草稿"
OUTPUT = ASSETS / "关键词套图评审/index.html"
PACKAGE = ASSETS / "Holo-ASO-当前候选套图-评审包.zip"
EXPECTED_SIZE = {
    "iphone-large": (1320, 2868),
    "ipad-13": (2064, 2752),
    "iphone-medium": (1206, 2622),
}


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def checked_page(device: str, page_id: str, page_manifest: dict) -> dict:
    image = ASSETS / "关键词候选" / device / f"{page_id}.png"
    sidecar = image.with_suffix(".json")
    if not image.is_file() or not sidecar.is_file():
        raise FileNotFoundError(f"{device}/{page_id}: 缺少候选图或sidecar")

    metadata = load_json(sidecar)
    data = image.read_bytes()
    if metadata.get("page_id") != page_id or metadata.get("device") != device:
        raise ValueError(f"{device}/{page_id}: sidecar 页面或设备不匹配")
    status = metadata.get("status", "")
    if "visual_review_passed" not in status and status != "passed_read_only_visual_review":
        raise ValueError(f"{device}/{page_id}: 缺少通过的视觉审阅状态")
    if metadata.get("demo_disclosure") != "演示数据":
        raise ValueError(f"{device}/{page_id}: 缺少演示数据披露")
    if metadata.get("output_mode") != "RGB":
        raise ValueError(f"{device}/{page_id}: sidecar输出模式不是RGB")
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{device}/{page_id}: 不是PNG")
    width, height = struct.unpack(">II", data[16:24])
    bit_depth = data[24]
    color_type = data[25]
    if (width, height) != EXPECTED_SIZE[device] or bit_depth != 8 or color_type != 2:
        raise ValueError(f"{device}/{page_id}: 尺寸、位深或RGB无透明通道规格不符合")
    digest = hashlib.sha256(data).hexdigest()
    if metadata.get("output_sha256") != digest:
        raise ValueError(f"{device}/{page_id}: sidecar SHA-256 不匹配")
    if metadata.get("release_mapping_status") != "unverified":
        raise ValueError(f"{device}/{page_id}: 发布映射状态不符合评审候选门禁")

    page = page_manifest.get(page_id, {})
    raw_sources = page.get("raw_sources", [])
    if not raw_sources:
        raise ValueError(f"{device}/{page_id}: manifest缺少原始来源标识")
    return {
        "id": page_id,
        "title": " / ".join(metadata.get("title_lines", [])),
        "subtitle": metadata.get("subtitle", ""),
        "status": metadata.get("status", "unknown"),
        "claim": metadata.get("claim", ""),
        "raw_sources": raw_sources,
        "image": "../关键词候选/" + device + "/" + page_id + ".png",
        "sha256": digest,
    }


def render(selection: dict, pages: dict) -> str:
    tabs = []
    panels = []
    for index, (device, config) in enumerate(selection["devices"].items()):
        active = " active" if index == 0 else ""
        tabs.append(
            f'<button class="tab{active}" data-device="{html.escape(device)}">'
            f'{html.escape(config["label"])}</button>'
        )
        sections = []
        for group in config["sets"]:
            cards = []
            for order, page_id in enumerate(group["page_ids"], 1):
                item = checked_page(device, page_id, pages)
                cards.append(card(item, order, False))
            alternates = []
            for page_id in group.get("alternates", []):
                item = checked_page(device, page_id, pages)
                alternates.append(card(item, None, True))
            alt_html = (
                '<h4>可替换候选</h4><div class="grid">' + "".join(alternates) + "</div>"
                if alternates else ""
            )
            sections.append(
                '<section class="set">'
                f'<header><span class="set-id">{html.escape(group["id"])}</span>'
                f'<h2>{html.escape(group["title"])}</h2>'
                f'<p>{html.escape(group["note"])}</p></header>'
                '<div class="grid">' + "".join(cards) + "</div>" + alt_html + '</section>'
            )
        blocked = "".join(
            '<li><b>' + html.escape(item["id"] + " · " + item["title"]) + "：</b>"
            + html.escape(item["note"]) + "</li>"
            for item in selection.get("blocked_series", [])
        )
        if blocked:
            sections.append(
                '<section class="blocked"><h2>暂不出图的关键词组</h2><ul>'
                + blocked + '</ul><p>来源不齐或真实链路未通过，继续保留阻塞状态。</p></section>'
            )
        panels.append(
            f'<main class="device{active}" data-device-panel="{html.escape(device)}">'
            + "".join(sections) + '</main>'
        )

    return """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Holo ASO 关键词套图评审</title>
<style>
:root{color-scheme:light;--ink:#24221f;--muted:#6c6861;--line:#e6e0d7;--paper:#faf8f4;--orange:#e97632;--card:#fff}
*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif}
.wrap{max-width:1500px;margin:auto;padding:30px 28px 70px}h1{font-size:32px;margin:0 0 8px}h2{font-size:22px;margin:2px 0 6px}.lede{max-width:950px;color:var(--muted);line-height:1.65}
.notice{background:#fff2e9;border:1px solid #f1c6a8;border-radius:12px;padding:14px 18px;margin:20px 0;color:#664020;line-height:1.6}
.toolbar{position:sticky;top:0;z-index:3;background:rgba(250,248,244,.94);backdrop-filter:blur(12px);padding:12px 0;border-bottom:1px solid var(--line);display:flex;gap:8px;flex-wrap:wrap}
.tab{border:1px solid #d5cec4;border-radius:999px;background:#fff;padding:10px 16px;font-size:14px;cursor:pointer;color:var(--ink)}.tab.active{background:var(--ink);color:#fff;border-color:var(--ink)}
.device{display:none}.device.active{display:block}.set{margin:30px 0 42px}.set header{margin-bottom:14px}.set-id{color:var(--orange);font-size:12px;font-weight:700;letter-spacing:.08em}.set p,.blocked p{color:var(--muted);line-height:1.55;margin:4px 0 12px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:16px}.shot{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px;box-shadow:0 3px 12px #251d1410}.shot img{display:block;width:100%;height:auto;border-radius:7px;background:#eee}.shot h3{font-size:14px;line-height:1.45;margin:10px 0 5px}.shot .sub{font-size:12px;color:var(--muted);line-height:1.5;min-height:34px}.shot .meta{font-size:11px;color:#77716a;margin-top:9px;word-break:break-all}.shot a{color:inherit;text-decoration:none}.shot a:hover h3{color:#b64d16}
h4{margin:22px 0 10px;color:#706a62}.alt{border-style:dashed}.blocked{border:1px solid var(--line);background:#f1eee9;border-radius:12px;padding:20px;margin-top:34px}.blocked ul{line-height:1.7;color:#514d47}.blocked p{margin-bottom:0}
footer{border-top:1px solid var(--line);margin-top:45px;padding-top:18px;color:var(--muted);font-size:12px;line-height:1.65}
@media(max-width:620px){.wrap{padding:22px 14px 48px}h1{font-size:26px}.grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:9px}.shot{padding:7px}.shot h3{font-size:12px}}
</style></head><body><div class="wrap">
<h1>Holo ASO 关键词套图评审</h1>
<p class="lede">按当前证据把真实 App 界面候选排成可比较的产品页顺序。每套 A/B 只代表同一搜索意图的不同文案表达；不是转化实验结果，也不是已发布页面。</p>
<div class="notice"><b>开发评审稿，不能直接上传。</b>候选来自隔离模拟器和合成演示数据。发布构建映射仍未核实；每张图的来源、声明和 SHA-256 见同名 sidecar。缺少证据的页会显示阻塞原因，不以功能名或拼图补位。<br><b>关键词边界：</b>""" + html.escape(selection["warning"]) + """</div>
<nav class="toolbar">""" + "".join(tabs) + "</nav>" + "".join(panels) + """
<footer>顺序根据17号当前候选建议生成。每个最终产品页最多选10张；A/B同一关键词只择一。图片文件仍在“关键词候选”目录，本页只做索引，不重绘或改写截图。<a href="../Holo-ASO-当前候选套图-评审包.zip">下载完整评审包（PNG与sidecar）</a>。以 App Store Connect 目标设备预览及正式发布包核验作为最终门槛。</footer>
</div><script>document.querySelectorAll('.tab').forEach(b=>b.addEventListener('click',()=>{document.querySelectorAll('.tab').forEach(x=>x.classList.toggle('active',x===b));document.querySelectorAll('.device').forEach(x=>x.classList.toggle('active',x.dataset.devicePanel===b.dataset.device))}));</script></body></html>"""


def build_package(selection: dict, pages: dict) -> None:
    manifest = {
        "warning": selection["warning"],
        "source_order_doc": selection["selection_basis"],
        "entries": [],
    }
    readme = """# Holo ASO 当前候选套图评审包

**本压缩包供本地评审与方案交接，不能直接上传 App Store Connect。**所有候选仍未匹配目标发布构建，开发与模拟器环境、记录来源和逐张 SHA-256 见 PNG 同名 sidecar。

## 内容结构

- `设备/系列/01-页面ID.png`：按推荐展示顺序排列的候选截图。
- `设备/系列/alternates/页面ID.png`：该关键词组的替换候选；不要和主序列全部叠加上传。
- 每张 PNG 同目录有 JSON sidecar，记录标题、原图来源、截图哈希、演示数据披露、视觉审阅状态及发布映射。
- `review-selection-source.json`：套图挑选规则；`review-selection.json`：本压缩包内文件与顺序、哈希的机器可读映射。

## 使用限制

- 图片来自隔离模拟器和合成演示数据；A/B 是同一关键词意图的备选表达，不是转化实验结果，同一 CPP 只选 A 或 B。
- D00-07只展示R18真实待确认草案，不证明已保存或已创建任务；它与计划关键词页K03-A/B-01属于不同产品页表达，不要在同一截图序列里重复使用。
- K01 仅有部分设备和页面来源；没有 R08 账目与凭证对应证据。K07、K08仍有来源/链路阻塞，不在本包中伪造补齐。
- K04 跳过完成率矛盾页；K05跳过重复主题页；iPad照片日记排除正文首句不完整的页面。
- 上传前须在实际发布构建核对产品功能、数据、授权/权益、屏幕布局、正式版本映射和 App Store Connect 设备预览。截图最多数量不代表每套必须凑满。
- 本包不改变 PNG 像素，也未上传任何素材。
"""

    PACKAGE.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(PACKAGE, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        archive.writestr("README.md", readme)
        archive.writestr(
            "review-selection-source.json",
            json.dumps(selection, ensure_ascii=False, indent=2) + "\n",
        )
        for device, config in selection["devices"].items():
            for group in config["sets"]:
                group_root = Path(device) / group["id"]
                for order, page_id in enumerate(group["page_ids"], 1):
                    item = checked_page(device, page_id, pages)
                    source = ASSETS / "关键词候选" / device / f"{page_id}.png"
                    source_sidecar = source.with_suffix(".json")
                    destination = group_root / f"{order:02d}-{page_id}.png"
                    destination_sidecar = destination.with_suffix(".json")
                    archive.write(source, destination.as_posix())
                    archive.write(source_sidecar, destination_sidecar.as_posix())
                    manifest["entries"].append({
                        "device": device,
                        "series": group["id"],
                        "page_id": page_id,
                        "order": order,
                        "alternate": False,
                        "archive_path": destination.as_posix(),
                        "sha256": item["sha256"],
                    })
                for alternate_order, page_id in enumerate(group.get("alternates", []), 1):
                    item = checked_page(device, page_id, pages)
                    source = ASSETS / "关键词候选" / device / f"{page_id}.png"
                    source_sidecar = source.with_suffix(".json")
                    destination = group_root / "alternates" / f"{alternate_order:02d}-{page_id}.png"
                    destination_sidecar = destination.with_suffix(".json")
                    archive.write(source, destination.as_posix())
                    archive.write(source_sidecar, destination_sidecar.as_posix())
                    manifest["entries"].append({
                        "device": device,
                        "series": group["id"],
                        "page_id": page_id,
                        "order": alternate_order,
                        "alternate": True,
                        "archive_path": destination.as_posix(),
                        "sha256": item["sha256"],
                    })
        archive.writestr(
            "review-selection.json",
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        )

    with zipfile.ZipFile(PACKAGE, "r") as archive:
        corrupt = archive.testzip()
        if corrupt:
            raise ValueError(f"评审包CRC损坏：{corrupt}")
        for entry in manifest["entries"]:
            digest = hashlib.sha256(archive.read(entry["archive_path"])).hexdigest()
            if digest != entry["sha256"]:
                raise ValueError(f"评审包图像哈希不匹配：{entry['archive_path']}")


def card(item: dict, order: int | None, alternate: bool) -> str:
    label = "替换" if alternate else f"{order:02d}"
    return (
        f'<article class="shot{" alt" if alternate else ""}">'
        f'<a href="{html.escape(item["image"])}" target="_blank" rel="noreferrer">'
        f'<img loading="lazy" src="{html.escape(item["image"])}" alt="{html.escape(item["id"])} 候选截图">'
        f'<h3>{html.escape(label)} · {html.escape(item["id"])} · {html.escape(item["title"])}</h3>'
        f'<div class="sub">{html.escape(item["subtitle"])}</div></a>'
        f'<div class="meta">状态：{html.escape(item["status"])}<br>来源：{html.escape(", ".join(item["raw_sources"]))}<br>SHA-256：{html.escape(item["sha256"])}</div>'
        '</article>'
    )


def main() -> None:
    selection = load_json(PLAN / "config/review-selection.json")
    manifest = load_json(PLAN / "config/production-manifest.json")
    page_manifest = {page["id"]: page for page in manifest["pages"]}
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    build_package(selection, page_manifest)
    OUTPUT.write_text(render(selection, page_manifest), encoding="utf-8")
    print(f"generated {OUTPUT}")
    print(f"packaged {PACKAGE}")


if __name__ == "__main__":
    main()

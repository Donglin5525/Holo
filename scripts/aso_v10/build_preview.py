#!/usr/bin/env python3
"""构建本轮已生成 ASO 候选图的只读 HTML 预览，不更改 PNG。"""
import argparse
import html
import json
from pathlib import Path

ROOT = Path(__file__).parents[2]
PLAN = ROOT / "docs/_common/plans/2026-10-30-Holo-AppStore宣传图重设计"
DELIVERY = ROOT.parent / "Holo-ASO-交付草稿"
DEVICE_CONFIG = {
    "iphone-large": {"label": "iPhone 6.9 英寸", "size": [1320, 2868]},
    "ipad-13": {"label": "iPad 13 英寸", "size": [2064, 2752]},
}

STATUS_LABELS = {
    "passed_read_only_visual_review": "视觉通过 · 发布版本未核对",
    "pending_read_only_visual_review": "等待视觉审阅",
    "revised_pending_second_pass": "修订后待二次审阅",
    "draft_visual_review_passed_release_mapping_unverified_not_for_upload": "视觉通过 · 发布版本未核对",
    "draft_visual_review_passed_pending_release_match": "视觉通过 · 待发布版本核对",
    "draft_visual_review_passed_pending_large_capture_and_release_match": "视觉通过 · 待大屏/发布版本核对",
    "draft_visual_review_pending_release_mapping_unverified_not_for_upload": "等待视觉审阅 · 发布版本未核对",
    "draft_partial_device_coverage_release_mapping_unverified_not_for_upload": "仅部分设备有稿 · 发布版本未核对",
}

CANDIDATE_STATUSES = {
    "passed_read_only_visual_review",
    "draft_visual_review_passed_release_mapping_unverified_not_for_upload",
    "draft_visual_review_passed_pending_release_match",
    "draft_visual_review_passed_pending_large_capture_and_release_match",
    "draft_visual_review_pending_release_mapping_unverified_not_for_upload",
    "draft_partial_device_coverage_release_mapping_unverified_not_for_upload",
}


def visual_status(page, device):
    """兼容旧版device_drafts与新候选页的顶层status。"""
    legacy = page.get("device_drafts", {}).get(device, {})
    if legacy.get("visual_review_status"):
        return legacy["visual_review_status"]
    device_candidate = page.get("device_candidate_status", {}).get(device, {})
    return device_candidate.get("status", page.get("status", "pending_read_only_visual_review"))


def status_label(page, device):
    """部分覆盖页显示本设备复核通过，但整套设备素材仍未完成。"""
    if page.get("status") == "draft_partial_device_coverage_release_mapping_unverified_not_for_upload":
        return "本设备视觉通过 · 其他设备缺来源 · 发布版本未核对"
    return STATUS_LABELS.get(visual_status(page, device), visual_status(page, device))


def is_visual_passed(page, device):
    status = visual_status(page, device)
    return status in {
        "passed_read_only_visual_review",
        "draft_visual_review_passed_release_mapping_unverified_not_for_upload",
        "draft_visual_review_passed_pending_release_match",
        "draft_visual_review_passed_pending_large_capture_and_release_match",
    }

def main():
    parser = argparse.ArgumentParser(description="为指定设备生成 Holo ASO 候选图的只读画廊")
    parser.add_argument("--device", choices=sorted(DEVICE_CONFIG), default="iphone-large")
    args = parser.parse_args()
    device = args.device
    device_info = DEVICE_CONFIG[device]
    reference_doc = "13-大屏候选复现与复核.md" if device == "iphone-large" else "14-iPad-13英寸候选复现与验收.md"
    image_dir = DELIVERY / "关键词候选" / device
    output = image_dir / "index.html"

    manifest = json.loads((PLAN / "config/production-manifest.json").read_text())
    pages = {page["id"]: page for page in manifest["pages"]}
    series_specs = {item["id"]: item for item in manifest["series"]}
    available_pages = {}
    for page in manifest["pages"]:
        if page.get("status") not in CANDIDATE_STATUSES:
            continue
        if visual_status(page, device) in {"rejected_read_only_visual_review", "diagnostic_only_not_candidate"}:
            continue
        if (image_dir / f"{page['id']}.png").is_file() and (image_dir / f"{page['id']}.json").is_file():
            available_pages[page["id"]] = page
    series = []
    for series_id, spec in series_specs.items():
        page_ids = sorted(
            (page_id for page_id, page in available_pages.items() if page["series_id"] == series_id),
            key=lambda page_id: available_pages[page_id]["order"],
        )
        if page_ids:
            summary = spec.get("story") or "、".join(spec.get("keywords", []))
            series.append((series_id, f"{spec['name']} · {summary}", page_ids))
    candidate_count = len(available_pages)
    keyword_group_count = sum(series_id != "D00" for series_id, _, _ in series)
    default_page_count = sum(1 for page in available_pages.values() if page["series_id"] == "D00")
    passed_count = sum(
        is_visual_passed(pages[page_id], device)
        for _, _, page_ids in series
        for page_id in page_ids
    )

    cards = []
    for series_id, series_title, page_ids in series:
        figures = []
        for page_id in page_ids:
            page = pages[page_id]
            report = json.loads((image_dir / f"{page_id}.json").read_text())
            status = visual_status(page, device)
            label = status_label(page, device)
            title = "".join(page["title_lines"])
            source_ids = "、".join(report["sources"])
            digest = report["output_sha256"]
            figures.append(f"""<figure class="card">
  <a class="image-link" href="{page_id}.png"><img src="{page_id}.png" alt="{html.escape(page_id + ' ' + title)}" loading="lazy"></a>
  <figcaption>
    <div class="card-top"><code>{page_id}</code><span class="status">{html.escape(label)}</span></div>
    <h3>{html.escape(title)}</h3>
    <p class="subtitle">{html.escape(page['subtitle'])}</p>
    <p>{html.escape(page['benefit'])}</p>
    <dl><dt>模拟器原图</dt><dd>{html.escape(source_ids)}</dd><dt>尺寸</dt><dd>{device_info['size'][0]} × {device_info['size'][1]} px · RGB</dd><dt>SHA-256</dt><dd class="sha">{digest}</dd></dl>
  </figcaption>
</figure>""")
        cards.append(f"<section><h2>{html.escape(series_id)} <small>{html.escape(series_title)}</small></h2><div class='grid'>{''.join(figures)}</div></section>")

    label = device_info["label"]
    document = f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Holo ASO · {html.escape(label)}候选</title>
<style>
:root{{color-scheme:light;--paper:#f7f5f0;--card:#fff;--ink:#262522;--muted:#69655f;--accent:#e85b27;--line:#e6e1d9}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--paper);color:var(--ink);font:16px/1.55 -apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB",sans-serif}}
header{{padding:38px max(24px,calc((100vw - 1440px)/2));background:#24231f;color:#fff}}header h1{{margin:0 0 8px;font-size:30px}}header p{{max-width:900px;margin:6px 0;color:#e5e1da}}header strong{{color:#ffb28d}}
main{{max-width:1440px;margin:0 auto;padding:24px}}section{{margin:0 0 38px}}h2{{display:flex;align-items:baseline;gap:12px;font-size:22px}}h2 small{{color:var(--muted);font-size:15px;font-weight:400}}
.grid{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:20px}}.card{{margin:0;background:var(--card);border:1px solid var(--line);border-radius:18px;overflow:hidden;display:grid;grid-template-columns:minmax(170px,0.72fr) minmax(250px,1fr);box-shadow:0 8px 26px #0000000a}}
.image-link{{display:flex;justify-content:center;align-items:flex-start;padding:14px;background:#edeae4}}img{{display:block;width:min(100%,310px);height:auto;border:1px solid #d9d4cb;border-radius:12px;background:#fff}}
figcaption{{padding:20px 20px 16px;min-width:0}}.card-top{{display:flex;align-items:center;justify-content:space-between;gap:8px}}code{{color:var(--accent);font-weight:700}}.status{{font-size:12px;color:#6a3a18;background:#fff1e7;border:1px solid #f1cfb6;border-radius:99px;padding:4px 8px}}
h3{{font-size:21px;line-height:1.35;margin:14px 0 5px}}figcaption p{{margin:7px 0;color:var(--muted)}}figcaption .subtitle{{color:#3d3a35}}dl{{display:grid;grid-template-columns:90px minmax(0,1fr);gap:5px 8px;margin:18px 0 0;font-size:12px}}dt{{color:var(--muted)}}dd{{margin:0;overflow-wrap:anywhere}}.sha{{font-family:ui-monospace,Menlo,monospace;font-size:10px}}
footer{{max-width:1440px;margin:0 auto;padding:0 24px 36px;color:var(--muted);font-size:13px}}
@media(max-width:900px){{.grid{{grid-template-columns:1fr}}}}
@media(max-width:600px){{main{{padding:16px}}header{{padding:25px 18px}}.card{{grid-template-columns:1fr}}.image-link{{max-height:660px;overflow:auto}}img{{width:min(100%,360px)}}figcaption{{padding:16px}}}}
</style></head><body>
<header><h1>Holo App Store 宣传图 · {html.escape(label)}候选</h1>
<p>{keyword_group_count}组关键词意图候选 + {default_page_count}张D00默认页，合计{candidate_count}张可追溯成图，当前视觉复核 {passed_count}/{candidate_count} 通过。每张输出都是 <strong>{device_info['size'][0]}×{device_info['size'][1]} RGB</strong>；App画面来自隔离模拟器中的Holo原生页面，外部合成素材在对应图片中单独标识，外层已披露“演示数据”。</p>
<p><strong>当前是本地开发候选</strong>：视觉状态按逐图审阅记录显示；所有图的发布版本映射均为 unverified，不得上传 App Store。</p></header>
<main>{''.join(cards)}</main>
<footer>财务、习惯和票据均为合成演示数据，不代表真实用户记录或真实消费。来源、复现命令、精确取景框和限制见 HOLO/docs/_common/plans/2026-10-30-Holo-AppStore宣传图重设计/{html.escape(reference_doc)}。七张与482.9%异常有关的内容页仍处于来源质量阻塞。</footer>
</body></html>"""
    output.write_text(document)
    print(output)


if __name__ == "__main__":
    main()

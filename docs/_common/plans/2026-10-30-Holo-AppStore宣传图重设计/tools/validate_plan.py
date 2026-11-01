#!/usr/bin/env python3
"""只读检查交接方案配置；不读取App数据，不启动模拟器，不验收成片。"""

from collections import Counter, defaultdict
import csv
import json
from pathlib import Path
import re
import sys
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
errors = []
checks = 0


def expect(condition, message):
    global checks
    checks += 1
    if not condition:
        errors.append(message)


def read_json(name):
    return json.loads((ROOT / 'config' / name).read_text())


def main():
    manifest = read_json('production-manifest.json')
    captures = read_json('capture-manifest.json')['captures']
    data = read_json('demo-data-blueprint.json')
    layouts = read_json('layouts.json')
    pages = manifest['pages']
    series = manifest['series']
    raw_ids = {x['id'] for x in captures}
    series_ids = {x['id'] for x in series}
    expect(len(series) == 17 == len(series_ids), '系列数量/身份应为17')
    expect(len(pages) == 106, '每设备应有106张')
    expect(len({p['id'] for p in pages}) == len(pages), '成片ID重复')
    expect(manifest['total_pages_three_devices'] == 318, '三设备总量应为318')
    expect(len(raw_ids) == 40 == len(captures), '原始拍摄卡应为40且唯一')
    counts = Counter(p['series_id'] for p in pages)
    for s in series:
        expected = 10 if s['id'] == 'D00' else 6
        expect(counts[s['id']] == expected == s['page_count'], f"{s['id']}页数不符")
        orders = sorted(p['order'] for p in pages if p['series_id'] == s['id'])
        expect(orders == list(range(1, expected + 1)), f"{s['id']}顺序不连续")
    used = set()
    output_paths = []
    for p in pages:
        used.update(p['raw_sources'])
        expect(p['series_id'] in series_ids, f"{p['id']}系列不存在")
        expect(set(p['raw_sources']) <= raw_ids, f"{p['id']}源图不存在")
        by_device = p.get('raw_sources_by_device', {})
        if by_device:
            device_source_union = set().union(*(set(items) for items in by_device.values()))
            expect(device_source_union == set(p['raw_sources']), f"{p['id']}设备来源并集与raw_sources不一致")
            expect(set(by_device) <= set(manifest.get('required_device_sequence', [])), f"{p['id']}设备来源包含非必需设备")
            expect(all(set(items) <= raw_ids for items in by_device.values()), f"{p['id']}设备来源引用不存在的原图")
        expect(set(p['required_sources']) | set(p['optional_sources']) == set(p['raw_sources']), f"{p['id']}必需/可选未覆盖")
        expect(not(set(p['required_sources']) & set(p['optional_sources'])), f"{p['id']}必需/可选冲突")
        expect(p['layout'] in layouts['layouts'], f"{p['id']}布局不存在")
        expect(1 <= len(p['title_lines']) <= 2 and all(p['title_lines']), f"{p['id']}标题行不合法")
        expect(bool(p['subtitle']) and bool(p['semantic_focus']), f"{p['id']}次文案或焦点为空")
        allowed_statuses = {
            'not_rendered',
            'blocked_source_quality',
            'draft_visual_review_pending_release_mapping_unverified_not_for_upload',
            'draft_visual_review_passed_pending_release_match',
            'draft_visual_review_passed_pending_large_capture_and_release_match',
            'draft_visual_review_passed_release_mapping_unverified_not_for_upload',
            'draft_visual_review_pending_release_mapping_unverified_not_for_upload',
            'passed_read_only_visual_review',
            'approved_for_upload',
        }
        expect(p['status'] in allowed_statuses, f"{p['id']}状态值无效")
        if p.get('draft_output'):
            expect(p.get('draft_status') == p['status'], f"{p['id']}草稿状态与页面状态不同步")
            expect(bool(p.get('draft_visual_review_status')), f"{p['id']}缺少草稿视觉审阅状态")
            expect(bool(p.get('draft_output_sha256')), f"{p['id']}草稿缺少输出SHA-256")
        fallback = p.get('fallback', {})
        if 'source' in fallback:
            expect(fallback['source'] in raw_ids, f"{p['id']}替代源不存在")
        if p['layout'] == 'PAIR':
            expect(len(p['raw_sources']) >= 2, f"{p['id']}PAIR缺第二张")
            expect(bool(p.get('source_relationship')), f"{p['id']}PAIR缺对应关系")
        if p['layout'] == 'JOURNAL':
            assets_by_device = p.get('export_asset_by_device', {})
            if assets_by_device:
                export_ids = set(p.get('required_export_assets', []))
                expect('R29' in export_ids or 'R29' in p['raw_sources'],
                       f"{p['id']}JOURNAL缺实际导出资产声明")
                for device in manifest.get('required_device_sequence', []):
                    asset = assets_by_device.get(device, {})
                    expect(bool(asset.get('file')) and bool(asset.get('sha256')),
                           f"{p['id']}JOURNAL缺少{device}实际导出路径或SHA")
                    expect(asset.get('format') == 'JPEG' and asset.get('pixel_size') == [1020, 932],
                           f"{p['id']}JOURNAL的{device}导出规格不符")
            else:
                # 尚未配置真实导出资产的 JOURNAL 页面只能停在待渲染/阻塞状态。
                expect(p['status'] in {'not_rendered', 'blocked_source_quality'},
                       f"{p['id']}JOURNAL没有导出资产却被标为已渲染")
        if p['layout'] == 'FLOW':
            expect(bool(p.get('auxiliary_assets')), f"{p['id']}FLOW缺输入凭证配置")
        if p['series_id'].startswith('K03') and p['order'] == 6:
            expect(p['source_variants'].get('R15') == 'completed', f"{p['id']}已完成图未配置变体")
        output_paths.append(p['output'])
    expect(len(set(output_paths)) == 106, '输出路径重复')
    for name, layout in layouts['layouts'].items():
        for slot, (x,y,w,h) in layout['slots'].items():
            expect(x >= 0 and y >= 0 and w > 0 and h > 0 and x+w <= 1206 and y+h <= 2622,
                   f'{name}/{slot}中屏槽位越界')
    for name, slots in layouts['ipad']['slots'].items():
        for slot, (x,y,w,h) in slots.items():
            expect(x >= 0 and y >= 0 and w > 0 and h > 0 and x+w <= 2064 and y+h <= 2752,
                   f'{name}/{slot}iPad槽位越界')
    with (ROOT/'config/finance-transactions-blueprint.csv').open(newline='') as f:
        rows = list(csv.DictReader(f))
    expect(len(rows) == 108, '历史交易应为108条')
    expect(len({r['logical_id'] for r in rows}) == 108, '历史交易逻辑ID重复')
    for r in rows:
        expect(int(r['amount_cents']) > 0 and 1 <= int(r['day']) <= 28, f"{r['logical_id']}金额/日期不合法")
        expect(r['direction'] in ['income','expense'], f"{r['logical_id']}方向不合法")
    observed = {}
    for off, expected_total, expected_dining, expected_count in [(-2,541000,108000,52),(-1,588000,140000,56)]:
        rs = [r for r in rows if int(r['month_offset']) == off]
        exp = sum(int(r['amount_cents']) for r in rs if r['direction']=='expense')
        inc = sum(int(r['amount_cents']) for r in rs if r['direction']=='income')
        food = sum(int(r['amount_cents']) for r in rs if r['category']=='餐饮')
        dinner = sum(int(r['amount_cents']) for r in rs if '聚餐' in r['name'])
        observed[str(off)] = {'transactions':len(rs),'expense_cents':exp,'income_cents':inc,'dining_cents':food,'dinner_cents':dinner}
        expect(len(rs) == expected_count, f'{off}月份笔数不符')
        expect(exp == expected_total and inc == 1200000 and food == expected_dining, f'{off}月份合计不符')
        expect(exp == data['finance_expected'][str(off)]['expense_cents'], f'{off}蓝图与CSV合计不符')
    expect(observed['-1']['dining_cents'] - observed['-2']['dining_cents'] == 32000, '餐饮差额不符')
    expect(observed['-1']['dinner_cents'] - observed['-2']['dinner_cents'] == 26600, '聚餐差额不符')
    project = sum(int(r['amount_cents']) for r in rows if r['project']=='城市漫游')
    expect(project == 24600 and data['project']['budget_cents'] - project == 55400, '项目预算不符')
    walk, reading = data['habits']
    offsets = walk['completed_day_offsets']
    expect(len(offsets)==37==len(set(offsets)), '散步完成日应为37且唯一')
    expect(offsets[-3:]==[-5,-1,0] and not({-4,-3,-2} & set(offsets)), '散步空白与恢复不符')
    expect(walk['seed_without_today'] is True and walk['expected_before_ui_action']==36, '散步首次播种边界不符')
    expect(len(reading['entries'])==18 and sum(r['value'] for r in reading['entries'])==600, '阅读18条600分钟不符')
    expect(len(data['notes'])==9 and len({n['id'] for n in data['notes']})==9, '想法身份不符')
    expect(all('expected_topic' in n and 'topic' not in n for n in data['notes']), '主题期望不应直接当播种关系')
    expect(sum(x['amount_cents'] for x in data['receipts']['REC-02']['entries'])==4950, '多笔凭证合计不符')
    card_text = (ROOT/'07-106张成片逐张配置.md').read_text()
    card_ids = re.findall(r'^## ((?:D00|K\d\d-[AB])-\d\d) ·', card_text, re.M)
    expect(set(card_ids)=={p['id'] for p in pages} and len(card_ids)==106, '逐张卡与机器配置不一致')
    raw_text = (ROOT/'06-原始截图逐张拍摄卡.md').read_text()
    expect(set(re.findall(r'^## (R\d\d) ·',raw_text,re.M))==raw_ids, '拍摄卡与机器配置不一致')
    for md in ROOT.glob('*.md'):
        for target in re.findall(r'\]\(([^)]+)\)',md.read_text()):
            if target.startswith(('http://','https://','#')):
                continue
            path = unquote(target.split('#',1)[0])
            expect((md.parent/path).exists(), f'{md.name}本地链接不存在：{target}')
    result = {'result':'plan_config_valid' if not errors else 'plan_config_invalid',
      'checks':checks,'errors':errors,'series':len(series),'pages_per_device':len(pages),
      'total_three_devices':len(pages)*3,'capture_cards':len(captures),
      'referenced_raw_ids':len(used),'historical_transactions':len(rows),
      'finance_observed':observed,
      'app_runtime_checked':False,'simulator_capture_checked':False,
      'image_files_checked':False,'full_set_visual_qa_completed':False,
      'scope':'仅计划、配置、数据蓝图与文档引用的一致性；不证明App能力、拍摄或成片通过'}
    print(json.dumps(result,ensure_ascii=False,indent=2))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())

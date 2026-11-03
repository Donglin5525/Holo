#!/usr/bin/env python3
"""生成隔离演示数据蓝图；不访问或修改 Holo 数据库。"""
import argparse
import calendar
import csv
import json
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo
from PIL import Image, ImageDraw, ImageFont


def month_start(today, offset):
    index = today.year * 12 + today.month - 1 + offset
    return date(index // 12, index % 12 + 1, 1)


def receipt_image(spec, today, multi):
    """生成通用演示凭证，文字和金额直接来自蓝图。"""
    image = Image.new('RGB', (900, 1280), '#f6f3ed')
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((55, 55, 845, 1225), radius=22, fill='white', outline='#dedad4', width=2)
    font = '/System/Library/Fonts/STHeiti Medium.ttc'
    large = ImageFont.truetype(font, 66)
    medium = ImageFont.truetype(font, 42)
    small = ImageFont.truetype(font, 30)
    def text(y, value, face=medium):
        draw.text((110, y), value, font=face, fill='#302d2a')
    text(110, spec.get('title', spec.get('merchant', '')), large)
    text(220, f'日期  {today.isoformat()}', small)
    draw.line((110, 285, 790, 285), fill='#d5d1ca', width=2)
    if multi:
        for index, item in enumerate(spec['entries']):
            amount = item['amount_cents']
            text(335 + index * 115, f"{item['merchant']}     ¥{amount // 100}.{amount % 100:02d}")
        amount = spec['total_cents']
        text(750, f'合计  ¥{amount // 100}.{amount % 100:02d}', large)
    else:
        amount = spec['amount_cents']
        text(355, f'¥{amount // 100}.{amount % 100:02d}', large)
        text(475, '人民币 · 支付完成')
    draw.line((110, 1000, 790, 1000), fill='#d5d1ca', width=2)
    text(1050, spec['label'], small)
    return image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--blueprint', required=True, type=Path)
    parser.add_argument('--finance', required=True, type=Path)
    parser.add_argument('--timezone', default='Asia/Shanghai')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--reference-date', type=date.fromisoformat)
    args = parser.parse_args()
    zone = ZoneInfo(args.timezone)
    now = datetime.now(zone)
    today = args.reference_date or now.date()
    blueprint = json.loads(args.blueprint.read_text())
    with args.finance.open(newline='', encoding='utf-8') as stream:
        rows = list(csv.DictReader(stream))
    instance = f"{blueprint['fixture_version']}-{today.isoformat()}-{uuid.uuid4().hex[:8]}"
    months = {offset: month_start(today, offset) for offset in (-2, -1)}
    transactions = []
    summaries = {}
    for offset, start in months.items():
        selected = [r for r in rows if int(r['month_offset']) == offset]
        summary = {'transactions': len(selected), 'income_cents': 0, 'expense_cents': 0,
                   'dining_cents': 0, 'dining_count': 0, 'dinner_cents': 0}
        for row in selected:
            amount = int(row['amount_cents'])
            day = int(row['day'])
            if amount <= 0 or day > calendar.monthrange(start.year, start.month)[1]:
                raise ValueError(f"无效交易: {row['logical_id']}")
            if row['direction'] not in ('income', 'expense'):
                raise ValueError(f"无效方向: {row['logical_id']}")
            item = dict(row)
            item['amount_cents'] = amount
            item['date'] = start.replace(day=day).isoformat()
            item['uuid'] = str(uuid.uuid5(uuid.NAMESPACE_URL, f"holo-aso/{blueprint['fixture_version']}/{row['logical_id']}"))
            transactions.append(item)
            summary[row['direction'] + '_cents'] += amount
            if row['category'] == '餐饮':
                summary['dining_cents'] += amount
                summary['dining_count'] += 1
            if '聚餐' in row['name']:
                summary['dinner_cents'] += amount
        if summary != blueprint['finance_expected'][str(offset)]:
            raise ValueError(f'{offset} 月汇总不匹配: {summary}')
        summaries[str(offset)] = summary
    if len({r['logical_id'] for r in transactions}) != len(transactions):
        raise ValueError('交易逻辑 ID 重复')
    # 一级分类是统计口径；二级分类用于满足实际入账约束。
    group_names = {'餐饮': '餐饮', '交通': '交通', '生活用品': '生活用品',
                   '居住': '居住', '通讯水电': '通讯水电', '购物': '购物',
                   '学习': '学习', '娱乐': '娱乐', '工资': '工资收入'}
    if any(r['category'] not in group_names for r in transactions):
        raise ValueError('演示交易包含未映射分类')
    category_groups = [
        {'blueprint_name': name, 'parent_name': parent,
         'child_name': '日常收入' if name == '工资' else '日常支出',
         'direction': 'income' if name == '工资' else 'expense'}
        for name, parent in group_names.items()
    ]
    project_total = sum(r['amount_cents'] for r in transactions if r['project'] == blueprint['project']['name'])
    if project_total != blueprint['project']['spent_cents']:
        raise ValueError('项目支出不匹配')
    walk, reading = blueprint['habits']
    if len(set(walk['completed_day_offsets'])) != 37 or sum(e['value'] for e in reading['entries']) != 600:
        raise ValueError('习惯蓝图不匹配')
    week_start = today - timedelta(days=today.weekday() + 7)
    variables = {'base_year': months[-2].year, 'base_month': months[-2].month,
                 'focus_year': months[-1].year, 'focus_month': months[-1].month,
                 'tomorrow_date': (today + timedelta(days=1)).isoformat(),
                 'day_plus_3_date': (today + timedelta(days=3)).isoformat(),
                 'day_plus_7_date': (today + timedelta(days=7)).isoformat(),
                 'last_week_start': week_start.isoformat(),
                 'last_week_end': (week_start + timedelta(days=6)).isoformat()}
    habits = []
    for habit in blueprint['habits']:
        item = dict(habit)
        if item['id'] == 'H-WALK':
            item['seed_dates'] = [(today + timedelta(days=offset)).isoformat()
                                  for offset in item['completed_day_offsets'] if offset < 0]
            if len(item['seed_dates']) != 36:
                raise ValueError('散步播种日期必须为36天')
        else:
            item['entries'] = [dict(entry, date=(today + timedelta(days=entry['day_offset'])).isoformat())
                               for entry in item['entries']]
        habits.append(item)
    notes = [dict(note, date=(today + timedelta(days=note['day_offset'])).isoformat())
             for note in blueprint['notes']]
    task_list = []
    local_midnight = datetime.combine(today, datetime.min.time(), tzinfo=zone)
    reference_time = now if today == now.date() else local_midnight + timedelta(hours=12)
    for item in blueprint['tasks']['today']:
        task = dict(item, due_date=today.isoformat(), source='static_history')
        if item['completed']:
            task['completed_at'] = max(local_midnight, reference_time - timedelta(minutes=2)).isoformat()
        task_list.append(task)
    week = blueprint['tasks']['last_complete_week']
    for status, titles in [('done', week['done_titles']), ('open', week['open_titles'])]:
        for index, title in enumerate(titles):
            task_date = week_start + timedelta(days=index)
            task = {'id': f'T-WEEK-{status.upper()}-{index + 1}', 'title': title,
                    'due_date': task_date.isoformat(), 'completed': status == 'done',
                    'source': 'static_history'}
            if task['completed']:
                task['completed_at'] = datetime.combine(task_date, datetime.min.time(), tzinfo=zone).replace(hour=18).isoformat()
            task_list.append(task)
    if len(task_list) != 10 or sum(t['completed'] for t in task_list) != 6:
        raise ValueError('任务蓝图数量不匹配')
    fixture = {'schema_version': 1, 'fixture_instance_id': instance,
               'reference_date': today.isoformat(), 'timezone': args.timezone,
               'blueprint': blueprint, 'transactions': transactions, 'category_groups': category_groups,
               'habits': habits, 'notes': notes, 'tasks': task_list,
               'resolved_inputs': {k: v.format(**variables) for k, v in blueprint['inputs'].items()}}
    expected = {'fixture_instance_id': instance, 'reference_date': today.isoformat(),
                'timezone': args.timezone, 'variables': variables, 'finance': summaries,
                'project_spent_cents': project_total, 'walk_before': 36, 'walk_after': 37,
                'reading_minutes': 600, 'status': 'blueprint_verified_not_seeded'}
    args.output.mkdir(parents=True, exist_ok=True)
    outputs = [('fixture.json', fixture), ('expected-values.json', expected)]
    receipt_names = ['receipt-single.png', 'receipt-multi.png']
    for name in receipt_names:
        if (args.output / name).exists():
            raise FileExistsError(f'拒绝覆盖已有文件: {args.output / name}')
    for name, _ in outputs:
        if (args.output / name).exists():
            raise FileExistsError(f'拒绝覆盖已有文件: {args.output / name}')
    single = receipt_image(blueprint['receipts']['REC-01'], today, False)
    multi = receipt_image(blueprint['receipts']['REC-02'], today, True)
    for name, value in outputs:
        target = args.output / name
        target.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    single.save(args.output / receipt_names[0])
    multi.save(args.output / receipt_names[1])
    print(json.dumps({'instance': instance, 'transactions': len(transactions), 'status': expected['status']}, ensure_ascii=False))


if __name__ == '__main__':
    main()

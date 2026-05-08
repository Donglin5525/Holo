#!/usr/bin/env node
// Moze Realm 数据库 → Holo 导入 CSV 转换工具
//
// 用法:
//   1. 先解压 Moze 导出包: unzip MOZE_4.0_xxx.zip -d /tmp/moze_extract
//   2. 复制 realm 文件（避免格式升级锁原文件）: cp /tmp/moze_extract/moze.realm /tmp/moze_extract/moze_copy.realm
//   3. 安装依赖: npm install --prefix /tmp/realm_tool realm
//   4. 运行: node moze_to_holo_csv.js <input_realm_path> <output_csv_path>
//      默认: input=/tmp/moze_extract/moze_copy.realm output=~/Desktop/moze_holo_import.csv
//
// 依赖: Node.js + realm npm 包（npm install realm）
//
// Holo 导入 CSV 格式（9列）:
//   日期,时间,类型,金额,一级分类,二级分类,账户,备注,标签
//
// Moze Realm 数据结构:
//   AHRecord: 记账记录（name, dateString, price, total, type, happenType, account, classification, project, tags, store, desc）
//   AHClassification: 分类（name, category）
//   AHCategory: 顶级分类（name, type）
//   AHAccount: 账户（name）
//   AHProject: 项目（name）
//   AHCurrency: 币种（code）
//
// 关键转换逻辑:
//   - 日期: "2022.07.11-15:07:46" → "2022/07/11" + "15:07"
//   - 金额: 取绝对值（Moze 负数=支出），类型由 type 字段判断
//   - 分类: Moze 扁平分类 → Holo 两级分类（一级+二级）
//   - 类型: type=0 支出, type=1 收入, type=15 分期利息(支出); happenType=2 分期付款

const Realm = require('realm');
const fs = require('fs');
const path = require('path');
const os = require('os');

// ========== 命令行参数 ==========
const args = process.argv.slice(2);
const inputPath = args[0] || '/tmp/moze_extract/moze_copy.realm';
const outputPath = args[1] || path.join(os.homedir(), 'Desktop', 'moze_holo_import.csv');

if (!fs.existsSync(inputPath)) {
  console.error('错误: Realm 文件不存在:', inputPath);
  console.error('用法: node moze_to_holo_csv.js [input.realm] [output.csv]');
  process.exit(1);
}

// ========== Moze → Holo 分类映射表 ==========
// key: Moze 分类名（已解析，非 CATEGORY_ 前缀的原始名）
// value: [Holo一级分类, Holo二级分类]

const categoryMapping = {
  // ---- 餐饮 ----
  '早餐': ['餐饮', '早餐'], '午餐': ['餐饮', '午餐'], '晚餐': ['餐饮', '晚餐'],
  '夜宵': ['餐饮', '夜宵'], '宵夜': ['餐饮', '夜宵'], '零食': ['餐饮', '零食'],
  '咖啡': ['餐饮', '咖啡'], '饮品': ['餐饮', '饮品'], '水果': ['餐饮', '水果'],
  '酒水': ['餐饮', '酒水'], '超市': ['餐饮', '超市'], '买菜': ['餐饮', '超市'],
  '外卖': ['餐饮', '外卖'],
  // ---- 交通 ----
  '打车': ['交通', '打车'], '地铁': ['交通', '地铁'], '公交': ['交通', '公交'],
  '骑行': ['交通', '单车'], '加油': ['交通', '加油'], '停车': ['交通', '停车'],
  '火车': ['交通', '火车'], '机票': ['交通', '机票'], '高速费': ['交通', '过路费'],
  '过路费': ['交通', '过路费'],
  // ---- 购物 ----
  '服饰': ['购物', '服饰'], '数码': ['购物', '数码'], '日用': ['购物', '日用'],
  '美妆': ['购物', '美妆'], '家具': ['购物', '家具'], '书籍': ['学习', '教材'],
  '运动': ['购物', '运动'], '礼物': ['购物', '礼物'], '衣服': ['购物', '服饰'],
  '护肤品': ['购物', '美妆'], '精品': ['购物', '礼物'], '配饰': ['购物', '服饰'],
  '鞋靴': ['购物', '服饰'], '箱包': ['购物', '服饰'],
  // ---- 娱乐 ----
  '电影': ['娱乐', '电影'], '游戏': ['娱乐', '游戏'], '视频': ['娱乐', '视频'],
  '音乐': ['娱乐', '音乐'], '旅游': ['娱乐', '旅游'], '健身': ['娱乐', '健身'],
  '射箭': ['娱乐', '健身'], '游泳🏊🏻': ['娱乐', '健身'], '羽毛球': ['娱乐', '健身'],
  '飞盘': ['娱乐', '健身'], '运动减肥': ['娱乐', '健身'],
  // ---- 居住 ----
  '房租': ['居住', '房租'], '房贷': ['居住', '房贷'], '水费': ['居住', '水费'],
  '电费': ['居住', '电费'], '燃气': ['居住', '燃气'], '物业费': ['居住', '物业'],
  '网费': ['居住', '网费'], '家电': ['居住', '家电'], '装修': ['居住', '装修'],
  '房屋杂项': ['居住', '其他'],
  // ---- 医疗 ----
  '医院': ['医疗', '就医'], '药品': ['医疗', '药品'], '检查': ['医疗', '体检'],
  '手术': ['医疗', '就医'], '口腔护理': ['医疗', '牙齿保健'], '医疗': ['医疗', '就医'],
  '保健': ['医疗', '保健品'],
  // ---- 学习 ----
  '课程': ['学习', '课程'], '考证': ['学习', '考试'], '文具': ['学习', '文具'],
  '学习': ['学习', '课程'], 'AI 订阅相关': ['学习', '订阅'],
  // ---- 人情 ----
  '红包': ['人情', '红包礼金'], '人情': ['人情', '其他'], '聚会': ['人情', '请客'],
  '捐赠': ['其他', '捐赠'],
  // ---- 其他 ----
  '宠物': ['其他', '宠物'], '理发': ['其他', '理发'], '美发': ['其他', '理发'],
  '洗衣': ['其他', '洗衣'], '话费': ['其他', '话费'], '维修': ['其他', '维修'],
  '保险': ['其他', '保险'], '还款': ['其他', '还款'], '转账': ['其他', '转账'],
  '其他': ['其他', '其他'], '一般': ['其他', '其他'], '我': ['其他', '其他'],
  '社交': ['其他', '社交'],
  // Moze 自定义顶级分类（作为 classification 名使用）
  '烟酒': ['其他', '烟酒'], '交通': ['交通', '其他'],
  '娱乐': ['娱乐', '其他'], '车': ['交通', '其他'],
  // ---- 收入 ----
  '工资': ['工资收入', '工资'], '奖金': ['工资收入', '奖金'],
  '兼职': ['工资收入', '兼职'], '报销': ['工资收入', '报销'],
  '出闲置': ['其他收入', '出闲置'], '利息': ['投资理财', '利息'],
  '投资': ['投资理财', '其他投资'], '基金投资': ['投资理财', '其他投资'],
  '租金': ['投资理财', '房租收入'], '退款': ['工资收入', '退款'],
  '存款计划': ['投资理财', '其他投资'], '公积金提取': ['其他收入', '公积金'],
  '信用卡': ['其他', '还款'], '信用借款': ['其他', '转账'],
  '个税补税': ['其他', '其他'],
};

// Moze 系统分类 ID（CATEGORY_* 前缀）→ 中文名映射
const systemCatMap = {
  'CATEGORY_3C': '数码', 'CATEGORY_ACCESSORY': '配饰', 'CATEGORY_ACCOMMODATION': '旅行',
  'CATEGORY_AIRPLANE': '机票', 'CATEGORY_ALCOHOL': '烟酒', 'CATEGORY_ALLOWANCE': '奖金',
  'CATEGORY_APP': '数码', 'CATEGORY_APPLIANCE': '家电', 'CATEGORY_BAG': '箱包',
  'CATEGORY_BIKE': '骑行', 'CATEGORY_BONUS': '奖金', 'CATEGORY_BOOK': '书籍',
  'CATEGORY_BOUTIQUE': '精品', 'CATEGORY_BREAKFAST': '早餐', 'CATEGORY_BUS': '公交',
  'CATEGORY_CAR': '加油', 'CATEGORY_CERTIFICATION': '考证', 'CATEGORY_CLOTHING': '衣服',
  'CATEGORY_COSMETICS': '美妆', 'CATEGORY_COURSE': '课程', 'CATEGORY_DINNER': '晚餐',
  'CATEGORY_DONATION': '捐赠', 'CATEGORY_DRINKS': '饮品', 'CATEGORY_ELECTRICITY': '电费',
  'CATEGORY_EXAMINATION': '检查', 'CATEGORY_EXHIBITION': '娱乐', 'CATEGORY_FITNESS': '健身',
  'CATEGORY_FRUITS': '水果', 'CATEGORY_FUEL': '加油', 'CATEGORY_FURNITURE': '家具',
  'CATEGORY_GAME': '游戏', 'CATEGORY_GAS': '燃气', 'CATEGORY_GIFT': '礼物',
  'CATEGORY_GROCERIES': '买菜', 'CATEGORY_HOSPITAL': '医院', 'CATEGORY_INSURANCE': '保险',
  'CATEGORY_INTERNET': '网费', 'CATEGORY_INVESTMENT': '投资', 'CATEGORY_LAUNDRY': '洗衣',
  'CATEGORY_LOTTERY': '娱乐', 'CATEGORY_LUNCH': '午餐', 'CATEGORY_MASSAGE': '医疗',
  'CATEGORY_MATERIAL': '日用', 'CATEGORY_MEDICINE': '药品', 'CATEGORY_MOBILE': '话费',
  'CATEGORY_MOTO': '交通', 'CATEGORY_MOVIE': '电影', 'CATEGORY_MUSIC': '音乐',
  'CATEGORY_OTHERS': '其他', 'CATEGORY_OUTDOORS': '运动', 'CATEGORY_PARKING': '停车',
  'CATEGORY_PARTY': '聚会', 'CATEGORY_PETS': '宠物', 'CATEGORY_PLAYGROUND': '娱乐',
  'CATEGORY_PUB': '娱乐', 'CATEGORY_RECREATION': '娱乐', 'CATEGORY_RENT': '房租',
  'CATEGORY_REPAIR': '维修', 'CATEGORY_REPAYMENT': '还款', 'CATEGORY_SALARY': '工资',
  'CATEGORY_SALON': '美发', 'CATEGORY_SHIP': '交通', 'CATEGORY_SHOES': '鞋靴',
  'CATEGORY_SOCIAL': '社交', 'CATEGORY_STATIONERY': '文具', 'CATEGORY_SUBWAY': '地铁',
  'CATEGORY_SUPERMARKET': '超市', 'CATEGORY_SUPPLIES': '日用', 'CATEGORY_SURGERY': '手术',
  'CATEGORY_SYSTEM_INTEREST': '利息', 'CATEGORY_TAXI': '打车', 'CATEGORY_TOOTH_CARE': '口腔护理',
  'CATEGORY_TRAIN': '火车', 'CATEGORY_TRAVEL': '旅行', 'CATEGORY_VIDEO': '视频',
  'CATEGORY_WATER': '水费',
};

// ========== 工具函数 ==========

function resolveClassName(name) {
  if (!name) return '';
  if (name.startsWith('CATEGORY_')) return systemCatMap[name] || name;
  return name;
}

function getHoloCategory(mozeName) {
  const resolved = resolveClassName(mozeName);
  if (categoryMapping[resolved]) return categoryMapping[resolved];
  return [resolved, resolved];
}

function escapeCSV(s) {
  if (!s) return '';
  s = String(s);
  if (s.includes(',') || s.includes('"') || s.includes('\n')) {
    return '"' + s.replace(/"/g, '""') + '"';
  }
  return s;
}

function roundAmount(v) {
  return Math.round(v * 100) / 100;
}

// ========== 主流程 ==========

const realm = new Realm({ path: inputPath });
const records = realm.objects('AHRecord').filtered('isDeleted == false');

const headers = ['日期', '时间', '类型', '金额', '一级分类', '二级分类', '账户', '备注', '标签'];
const rows = [headers.join(',')];

const stats = { total: 0, expense: 0, income: 0, special: 0, unmapped: new Set() };

records.forEach(r => {
  stats.total++;

  // 日期: "2022.07.11-15:07:46" → "2022/07/11" + "15:07"
  const dateStr = r.dateString || '';
  let date = '', time = '';
  const m = dateStr.match(/^(\d{4})\.(\d{2})\.(\d{2})-(\d{2}):(\d{2})/);
  if (m) {
    date = m[1] + '/' + m[2] + '/' + m[3];
    time = m[4] + ':' + m[5];
  } else {
    date = dateStr.replace(/\./g, '/');
  }

  // 类型: 0=支出, 1=收入, 15=分期利息(支出), happenType=2 分期付款
  let type;
  if (r.type === 1) { type = '收入'; stats.income++; }
  else { type = '支出'; stats.expense++; }
  if (r.type === 15 || r.happenType === 2) stats.special++;

  // 金额: 取绝对值（Holo 由类型列判断收支）
  const amount = roundAmount(Math.abs(r.total != null ? r.total : r.price));

  // 分类: Moze 扁平 → Holo 两级
  const mozeClass = r.classification ? r.classification.name : '';
  const [primaryCat, subCat] = getHoloCategory(mozeClass);
  if (!categoryMapping[resolveClassName(mozeClass)]) {
    stats.unmapped.add(resolveClassName(mozeClass));
  }

  // 备注: 合并 name + desc
  const noteParts = [];
  if (r.name) noteParts.push(r.name);
  if (r.desc) noteParts.push(r.desc);
  const note = noteParts.join(' ');

  // 标签: 逗号转分号（Holo 用分号分隔多标签）
  const tags = (r.tags || '').replace(/,/g, ';');

  rows.push([
    date, time, type, amount,
    escapeCSV(primaryCat), escapeCSV(subCat),
    escapeCSV(r.account ? r.account.name : ''),
    escapeCSV(note),
    escapeCSV(tags)
  ].join(','));
});

const csv = rows.join('\n');
fs.writeFileSync(outputPath, '﻿' + csv, 'utf-8'); // BOM 头，Excel 兼容

console.log('=== 导出完成 ===');
console.log('输入:', inputPath);
console.log('输出:', outputPath);
console.log('总记录:', stats.total);
console.log('支出:', stats.expense, '| 收入:', stats.income);
console.log('特殊记录(分期):', stats.special);
console.log('未映射分类:', [...stats.unmapped].join(', ') || '无');

realm.close();

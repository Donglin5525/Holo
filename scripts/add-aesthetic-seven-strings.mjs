#!/usr/bin/env node
// 审美提升七项 · 三语词表补齐（一次性脚本，文本插入不重排整文件）
// 用法: node scripts/add-aesthetic-seven-strings.mjs （仓库根执行）
// 只追加缺失 key（已存在的跳过）；锚点在 "strings" : { 之后，格式 mimic Xcode（" : "）。
// 模式来源: scripts/add-receipt-booking-strings.mjs
// 词表真源: docs/_common/plans/2026-11-23-审美提升七项/01-实施方案.md（§3.3 / §4.6 / §8.3 / §9.3）
import fs from 'node:fs';

const FILE = 'Holo/Holo APP/Holo/Holo/Localizable.xcstrings';

// key = zh-Hans 源文；[zh-Hant, en]
const ENTRIES = [
  // ---- P4 刊头：周数与二十四节气（§3.3 / §3.4）----
  ['第 %lld 周', ['第 %lld 週', 'Week %lld']],
  ['第 %lld 周，%@', ['第 %lld 週，%@', 'Week %lld, %@']],
  ['小寒', ['小寒', 'Minor Cold']],
  ['大寒', ['大寒', 'Major Cold']],
  ['立春', ['立春', 'Start of Spring']],
  ['雨水', ['雨水', 'Rain Water']],
  ['惊蛰', ['驚蟄', 'Awakening of Insects']],
  ['春分', ['春分', 'Spring Equinox']],
  ['清明', ['清明', 'Pure Brightness']],
  ['谷雨', ['穀雨', 'Grain Rain']],
  ['立夏', ['立夏', 'Start of Summer']],
  ['小满', ['小滿', 'Grain Buds']],
  ['芒种', ['芒種', 'Grain in Ear']],
  ['夏至', ['夏至', 'Summer Solstice']],
  ['小暑', ['小暑', 'Minor Heat']],
  ['大暑', ['大暑', 'Major Heat']],
  ['立秋', ['立秋', 'Start of Autumn']],
  ['处暑', ['處暑', 'End of Heat']],
  ['白露', ['白露', 'White Dew']],
  ['秋分', ['秋分', 'Autumn Equinox']],
  ['寒露', ['寒露', 'Cold Dew']],
  ['霜降', ['霜降', "Frost's Descent"]],
  ['立冬', ['立冬', 'Start of Winter']],
  ['小雪', ['小雪', 'Minor Snow']],
  ['大雪', ['大雪', 'Major Snow']],
  ['冬至', ['冬至', 'Winter Solstice']],

  // ---- P1 页头「今日的灯」（§4.6）----
  ['今天点亮了 %lld / %lld', ['今天點亮了 %lld / %lld', '%lld of %lld lit today']],
  ['今天点亮了', ['今天點亮了', 'Lit today']],

  // ---- P5 空态短句（§8.3）----
  ['今天还是\n一张白纸。', ['今天還是\n一張白紙。', 'Today is still\na blank page.']],
  ['— 想做点什么，就写下来', ['— 想做點什麼，就寫下來', '— Write down what you want to do']],
  ['写第一件事', ['寫第一件事', 'Write the first one']],
  ['今天没什么非做不可的事。', ['今天沒什麼非做不可的事。', 'Nothing you must do today.']],
  ['— 好好过', ['— 好好過', '— Enjoy it']],
  ['念头来得快，\n走得也快。', ['念頭來得快，\n走得也快。', 'Thoughts come fast,\nand leave just as fast.']],
  ['— 抓住一个', ['— 抓住一個', '— Catch one']],
  ['记一条想法', ['記一條想法', 'Jot a thought']],
  ['这里会慢慢\n长出你的日子。', ['這裡會慢慢\n長出你的日子。', 'Your days will\ngrow here, slowly.']],
  ['— 写下的想法、账单、打卡，会按日期出现在这里', ['— 寫下的想法、帳單、打卡，會按日期出現在這裡', '— Thoughts, expenses and check-ins appear here by date']],
  ['还没有放下过什么。', ['還沒有放下過什麼。', 'Nothing set aside yet.']],
  ['还没有收起来的清单。', ['還沒有收起來的清單。', 'No archived lists yet.']],
  ['遇到喜欢的，\n点星标留下来。', ['遇到喜歡的，\n點星標留下來。', 'Star the ones\nyou love to keep them.']],
  // 复用既有文案做副句时的「— 」前缀（副句正文由调用方本地化后传入）
  ['— %@', ['— %@', '— %@']],

  // ---- P6 设置项「纸张」（§9.3）----
  ['纸张', ['紙張', 'Paper']],
  ['随时间变换纸色', ['隨時間變換紙色', 'Paper that follows the day']],
  ['早晨更亮，夜里更暖。只影响首页和我的积累。', ['早晨更亮，夜裡更暖。只影響首頁和我的積累。', 'Brighter in the morning, warmer at night. Home and My Journey only.']],
  ['旧记忆慢慢泛黄', ['舊記憶慢慢泛黃', 'Let old memories yellow']],
  ['记忆长廊里越早的日子，纸色越旧。', ['記憶長廊裡越早的日子，紙色越舊。', 'In Memory Gallery, older days look like older paper.']],
];

function entryText(key, hant, en) {
  return [
    `    ${JSON.stringify(key)} : {`,
    `      "localizations" : {`,
    `        "en" : {`,
    `          "stringUnit" : {`,
    `            "state" : "translated",`,
    `            "value" : ${JSON.stringify(en)}`,
    `          }`,
    `        },`,
    `        "zh-Hant" : {`,
    `          "stringUnit" : {`,
    `            "state" : "translated",`,
    `            "value" : ${JSON.stringify(hant)}`,
    `          }`,
    `        }`,
    `      }`,
    `    },`,
  ].join('\n');
}

let text = fs.readFileSync(FILE, 'utf8');
const anchor = '"strings" : {\n';
const anchorAt = text.indexOf(anchor);
if (anchorAt < 0) { console.error('anchor not found'); process.exit(1); }
const insertAt = anchorAt + anchor.length;

// 幂等：已存在的 key 跳过
const existing = JSON.parse(text).strings;
const blocks = [];
let added = 0, skipped = 0;
for (const [key, [hant, en]] of ENTRIES) {
  if (existing[key]) { skipped++; continue; }
  blocks.push(entryText(key, hant, en));
  added++;
}
if (blocks.length > 0) {
  text = text.slice(0, insertAt) + blocks.join('\n') + '\n' + text.slice(insertAt);
  fs.writeFileSync(FILE, text);
}
// 落盘后校验 JSON 合法
const after = JSON.parse(fs.readFileSync(FILE, 'utf8'));
const missing = ENTRIES.filter(([key]) => !after.strings[key]);
if (missing.length > 0) { console.error('keys still missing:', missing.map(([k]) => k)); process.exit(1); }
console.log(`added ${added}, skipped ${skipped}, total keys ${Object.keys(after.strings).length}`);

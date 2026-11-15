#!/usr/bin/env node
// 记忆长廊·随机漫步「一束暖光」三语词表补齐（一次性脚本，文本插入不重排整文件）
// 用法: node scripts/add-random-walk-strings.mjs （仓库根执行）
// 只追加缺失 key（已存在的跳过）；锚点在 "strings": { 之后，格式 mimic Xcode。
import fs from 'node:fs';

const FILE = 'Holo/Holo APP/Holo/Holo/Localizable.xcstrings';

// key = zh-Hans 源文；[zh-Hant, en]
const ENTRIES = [
  ['随机漫步', ['隨機漫步', 'Random Walk']],
  ['去一个有记录的旧日', ['去一個有記錄的舊日', 'Visit a day with records']],
  ['关闭', ['關閉', 'Close']],
  ['再走一天', ['再走一天', 'Another Day']],
  ['重新漫步', ['重新漫步', 'Start Over']],
  ['在长廊看这天', ['在長廊看這天', 'See This Day in the Gallery']],
  ['在长廊看全部 %lld 条', ['在長廊看全部 %lld 條', 'See All %lld in the Gallery']],
  ['那天的记录', ['那天的記錄', 'Records That Day']],
  ['那天的记录 · %lld', ['那天的記錄 · %lld', 'Records That Day · %lld']],
  ['回看一句', ['回看一句', 'A Line to Look Back On']],
  ['查看这句的来源 ›', ['查看這句的來源 ›', 'View Source ›']],
  ['正在找一段旧日记录', ['正在找一段舊日記錄', 'Finding a past day…']],
  ['暂时无法载入旧日记录', ['暫時無法載入舊日記錄', "Couldn't load past records"]],
  ['重试', ['重試', 'Retry']],
  ['还没有可漫步的旧日', ['還沒有可漫步的舊日', 'No old days to visit yet']],
  ['长廊里有了更早的记录，就可以回来走走', ['長廊裡有了更早的記錄，就可以回來走走', 'Once the gallery has earlier records, come back for a walk']],
  ['距今天 %lld 天', ['距今天 %lld 天', '%lld days ago']],
  ['正在回到那一天', ['正在回到那一天', 'Going back to that day']],
  ['找日期', ['找日期', 'Find a Date']],
  ['回到最近', ['回到最近', 'Back to Latest']],
  ['今天', ['今天', 'Today']],
  ['出发', ['出發', 'Depart']],
  ['想起那一天', ['想起那一天', 'Remembering That Day']],
  ['当天', ['當天', 'That day']],
  ['你那天写道：“%@”', ['你那天寫道：「%@」', 'You wrote that day: "%@"']],
  ['这一天的记录大多留在傍晚以后', ['這一天的記錄大多留在傍晚以後', 'Most records that day were made after dusk']],
];

function entryText(key, hant, en) {
  return [
    `    ${JSON.stringify(key)}: {`,
    `      "localizations": {`,
    `        "zh-Hant": {`,
    `          "stringUnit": {`,
    `            "state": "translated",`,
    `            "value": ${JSON.stringify(hant)}`,
    `          }`,
    `        },`,
    `        "en": {`,
    `          "stringUnit": {`,
    `            "state": "translated",`,
    `            "value": ${JSON.stringify(en)}`,
    `          }`,
    `        }`,
    `      }`,
    `    },`,
  ].join('\n');
}

const source = fs.readFileSync(FILE, 'utf8');
const anchor = '  "strings" : {\n';
const anchorIndex = source.indexOf(anchor);
if (anchorIndex < 0) throw new Error('锚点 "strings" : { 未找到');

let added = 0;
let skipped = 0;
const insertion = ENTRIES.map(([key, [hant, en]]) => {
  if (source.includes(`"${key.replace(/"/g, '\\"')}": {`) || source.includes(`${JSON.stringify(key)}: {`)) {
    skipped += 1;
    return '';
  }
  added += 1;
  return entryText(key, hant, en) + '\n';
}).filter(Boolean).join('');

if (added > 0) {
  const at = anchorIndex + anchor.length;
  fs.writeFileSync(FILE, source.slice(0, at) + insertion + source.slice(at));
}
console.log(`随机漫步词条：新增 ${added} 个，已存在跳过 ${skipped} 个`);

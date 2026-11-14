#!/usr/bin/env node
// 记忆长廊·随机漫步「一束暖光」三语词表补齐（一次性脚本，文本插入不重排整文件）
// 用法: node scripts/add-random-walk-strings.mjs （仓库根执行）
// 只追加缺失 key（已存在的跳过）；锚点在 "strings": { 之后，格式 mimic Xcode。
import fs from 'node:fs';

const FILE = 'Holo/Holo APP/Holo/Holo/Localizable.xcstrings';

// key = zh-Hans 源文；[zh-Hant, en]
const ENTRIES = [
  ['长廊', ['長廊', 'Gallery']],
  ['收起当天', ['收起當天', 'Collapse']],
  ['当天 %lld 条记录', ['當天 %lld 條記錄', '%lld records that day']],
  ['已到最早的记录', ['已到最早的記錄', 'Earliest records reached']],
  ['长廊还没有记录', ['長廊還沒有記錄', 'No records in the gallery yet']],
  ['写条想法', ['寫條想法', 'Write a Note']],
  ['写下的想法、账单、打卡和完成的任务，会按日期出现在这里。', ['寫下的想法、賬單、打卡和完成的任務，會按日期出現在這裡。', 'Notes, expenses, check-ins and finished tasks will appear here by date.']],
  ['正在打开长廊', ['正在打開長廊', 'Opening the gallery']],
  ['正在读取你的记录。', ['正在讀取你的記錄。', 'Reading your records.']],
  ['暂时无法载入记录', ['暫時無法載入記錄', "Couldn't load records"]],
  ['可以稍后再试一次。', ['可以稍後再試一次。', 'Try again later.']],
  ['这一天没有记录', ['這一天沒有記錄', 'No records this day']],
  ['这一天暂无已载入的记录', ['這一天暫無已載入的記錄', 'No loaded records this day yet']],
  ['去最近有记录的一天', ['去最近有記錄的一天', 'Go to the nearest day with records']],
  ['暂未载入', ['暫未載入', 'not loaded yet']],
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

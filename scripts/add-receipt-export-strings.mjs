#!/usr/bin/env node
// 导出含小票图片 · 三语词表补齐（一次性脚本，文本插入不重排整文件）
// 用法: node scripts/add-receipt-export-strings.mjs （仓库根执行）
// 模式来源: scripts/add-receipt-booking-strings.mjs
import fs from 'node:fs';

const FILE = 'Holo/Holo APP/Holo/Holo/Localizable.xcstrings';

// key = zh-Hans 源文；[zh-Hant, en]
const ENTRIES = [
  ['导出交易记录为 CSV/JSON，可含小票图片', ['導出交易記錄為 CSV/JSON，可含小票圖片', 'Export transactions as CSV/JSON, with optional receipt images']],
  ['包含小票图片', ['包含小票圖片', 'Include receipt images']],
  ['打包为 ZIP：账目数据 + 按日期命名的小票图片', ['打包為 ZIP：賬目數據 + 按日期命名的小票圖片', 'Bundled as ZIP: ledger data + receipt images named by date']],
];

function entryText(key, hant, en) {
  return [
    `    ${JSON.stringify(key)} : {`,
    `      "extractionState": "manual",`,
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
JSON.parse(fs.readFileSync(FILE, 'utf8'));
console.log(`added=${added} skipped=${skipped}`);

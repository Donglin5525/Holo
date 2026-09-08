#!/usr/bin/env node
// 截图识别记账 · 三语词表补齐（一次性脚本，文本插入不重排整文件）
// 用法: node scripts/add-vision-strings.mjs  （仓库根执行）
// 只追加缺失 key（已存在的跳过）；锚点在 "strings": { 之后，格式 mimic Xcode。
import fs from 'node:fs';

const FILE = 'Holo/Holo APP/Holo/Holo/Localizable.xcstrings';

// key = zh-Hans 源文；[zh-Hant, en]
const ENTRIES = [
  ['[图片]', ['[圖片]', '[Image]']],
  ['正在看图…', ['正在看圖…', 'Looking at the image…']],
  ['图片识别记账', ['圖片識別記賬', 'Scan to log an expense']],
  ['识别图片记账', ['識別圖片記賬', 'Log from a photo']],
  ['拍照', ['拍照', 'Take Photo']],
  ['从相册选择', ['從相簿選擇', 'Choose from Library']],
  ['识别的图片', ['識別的圖片', 'Scanned image']],
  ['图片读取失败，请换一张试试', ['圖片讀取失敗，請換一張試試', "Couldn't read that image. Try another one."]],
  ['这张图我不太看得清金额，不敢替你记。重新拍一张清楚的，或者手动记一笔？', ['這張圖我不太看得清金額，不敢替你記。重新拍一張清楚的，或者手動記一筆？', "The amount isn't clear enough for me to log it confidently. Retake a sharper photo, or add it manually?"]],
  ['图里像是消费凭证，但我没能可靠地认出金额。重新拍一张，或手动记一笔？', ['圖裡像是消費憑證，但我沒能可靠地認出金額。重新拍一張，或手動記一筆？', "This looks like a receipt, but I couldn't read the amount reliably. Retake the photo, or add it manually?"]],
  ['这是转账/还款类截图，属于资金流转，我不把它记成消费。', ['這是轉帳/還款類截圖，屬於資金流轉，我不把它記成消費。', "This is a transfer/repayment screenshot — money movement, not spending. I won't log it as an expense."]],
  ['这是理财/余额页面，没有需要记的账。', ['這是理財/餘額頁面，沒有需要記的賬。', "This is an investments/balance page — nothing to log here."]],
  ['这是一份清单。清单转任务功能还在路上，辛苦先手动建任务。', ['這是一份清單。清單轉任務功能還在路上，辛苦先手動建任務。', "This is a list. Turning lists into tasks is coming soon — please create tasks manually for now."]],
  ['这是外币消费，目前只支持人民币记账，可以换算后手动记一笔。', ['這是外幣消費，目前只支持人民幣記賬，可以換算後手動記一筆。', "This is a foreign-currency purchase. Only CNY is supported for now — convert and add it manually."]],
  ['订单还没支付。支付完成后再拍给我，我帮你记。', ['訂單還沒支付。支付完成後再拍給我，我幫你記。', "This order isn't paid yet. Show it to me again after payment and I'll log it."]],
  ['这张图里我没找到能记的账。拍张小票或支付截图试试？', ['這張圖裡我沒找到能記的賬。拍張小票或支付截圖試試？', "I couldn't find anything to log in this image. Try a receipt or a payment screenshot?"]],
  ['这张图我没能可靠地变成一笔账。重新拍一张清楚的，或手动记一笔？', ['這張圖我沒能可靠地變成一筆賬。重新拍一張清楚的，或手動記一筆？', "I couldn't turn this image into a transaction reliably. Retake a clearer photo, or add it manually?"]],
  ['【图片记账】请把图片里识别出的以下交易记下来：', ['【圖片記賬】請把圖片裡識別出的以下交易記下來：', '[Scan to log] Please log the following transactions recognized from the image:']],
  ['，商户「%@」', ['，商戶「%@」', ', merchant "%@"']],
  ['，日期 %@', ['，日期 %@', ', date %@']],
  ['支付方式：%@', ['支付方式：%@', 'Paid via %@']],
  ['明细：%@', ['明細：%@', 'Items: %@']],
  ['用户附言：「%@」', ['用戶附言：「%@」', 'User note: "%@"']],
  ['提醒：这笔可能已经记过（%@ ¥%@），确认前请留意，避免重复。', ['提醒：這筆可能已經記過（%@ ¥%@），確認前請留意，避免重複。', 'Heads-up: this may already be logged (%@ ¥%@). Double-check before confirming to avoid duplicates.']],
  ['需要相册权限才能选图识别。请在系统设置 > Holo > 照片中允许访问。', ['需要相簿權限才能選圖識別。請在系統設定 > Holo > 照片中允許存取。', 'Photo library access is needed to pick images. Allow it in Settings > Holo > Photos.']],
  ['这张图暂时加载不了（可能在 iCloud 里取不到），换一张试试。', ['這張圖暫時載入不了（可能在 iCloud 裡取不到），換一張試試。', "This image couldn't be loaded right now (it may be unavailable in iCloud). Try another one."]],
  ['收入', ['收入', 'Income']],
  ['支出', ['支出', 'Expense']],
  ['取消', ['取消', 'Cancel']],
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

let text = fs.readFileSync(FILE, 'utf8');
const anchor = '"strings": {\n';
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

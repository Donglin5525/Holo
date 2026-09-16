#!/usr/bin/env node
// 图片快捷指令自动记账 · 三语词表补齐（一次性脚本，文本插入不重排整文件）
// 用法: node scripts/add-receipt-booking-strings.mjs （仓库根执行）
// 只追加缺失 key（已存在的跳过）；锚点在 "strings": { 之后，格式 mimic Xcode。
// 模式来源: scripts/add-vision-strings.mjs（2026-09-09 截图识别记账批）
import fs from 'node:fs';

const FILE = 'Holo/Holo APP/Holo/Holo/Localizable.xcstrings';

// key = zh-Hans 源文；[zh-Hant, en]
const ENTRIES = [
  // ---- Intent 动作与参数（§22.1）----
  ['识别图片并记账', ['識別圖片並記賬', 'Recognize & Log a Receipt']],
  ['把支付成功截图或小票照片交给 Holo 识别：金额、商户、日期、支付方式，安全时自动记账。', ['把支付成功截圖或小票照片交給 Holo 識別：金額、商戶、日期、支付方式，安全時自動記賬。', 'Hand a payment screenshot or receipt photo to Holo: amount, merchant, date and payment method are recognized, and booked automatically when safe.']],
  ['图片', ['圖片', 'Image']],
  ['支付成功截图或小票照片（只取第一张）', ['支付成功截圖或小票照片（只取第一張）', 'Payment screenshot or receipt photo (first image only)']],
  ['选择要记账的图片', ['選擇要記賬的圖片', 'Choose an image to log']],
  ['自动识别，或固定某个账户', ['自動識別，或固定某個賬戶', 'Detect automatically, or fix to a specific account']],
  ['不挂项目，按图匹配，或固定某个项目', ['不掛項目，按圖匹配，或固定某個項目', 'None, match from the image, or fix to a specific project']],
  ['安全时自动记账，或始终先确认', ['安全時自動記賬，或始終先確認', 'Auto-book when safe, or always confirm first']],
  ['可选：补充说明，如「这是昨天的，挂东京旅行」', ['可選：補充說明，如「這是昨天的，掛東京旅行」', 'Optional: extra context, e.g. "This was yesterday, log it to Tokyo Trip"']],
  ['处理方式', ['處理方式', 'Booking Mode']],
  ['安全时自动记账', ['安全時自動記賬', 'Auto-book when safe']],
  ['金额状态可靠时直接入账', ['金額狀態可靠時直接入賬', 'Books it directly when amount and status are reliable']],
  ['始终先确认', ['始終先確認', 'Always confirm first']],
  ['全部生成待复核项', ['全部生成待複核項', 'Always create review items']],
  ['财务项目', ['財務項目', 'Finance Project']],
  ['自动识别', ['自動識別', 'Auto-detect']],
  ['按支付渠道与尾号匹配', ['按支付渠道與尾號匹配', 'Matches by payment channel and card tail digits']],
  ['不挂项目', ['不掛項目', 'No project']],
  ['按图片/附言明确匹配', ['按圖片/附言明確匹配', 'Match explicitly from image or note']],
  ['图里或附言写清项目名才会挂', ['圖裡或附言寫清項目名才會掛', 'Attaches only when the project name is clear in the image or note']],
  ['已归档', ['已歸檔', 'Archived']],
  ['已结束', ['已結束', 'Ended']],

  // ---- Intent 结果文字（§22.1 首版规范）----
  ['这张图已经记过：%@', ['這張圖已經記過：%@', 'This image was already logged: %@']],
  ['图里有多笔交易，未入账。打开 Holo 逐笔确认。', ['圖裡有多筆交易，未入賬。打開 Holo 逐筆確認。', 'Multiple transactions in this image — not booked. Open Holo to confirm each one.']],
  ['金额不确定，未入账。打开 Holo 确认。', ['金額不確定，未入賬。打開 Holo 確認。', 'Amount uncertain — not booked. Open Holo to confirm.']],
  ['收支方向不确定，未入账。打开 Holo 确认。', ['收支方向不確定，未入賬。打開 Holo 確認。', 'Income/expense direction uncertain — not booked. Open Holo to confirm.']],
  ['支付状态不确定，未入账。打开 Holo 确认。', ['支付狀態不確定，未入賬。打開 Holo 確認。', 'Payment status uncertain — not booked. Open Holo to confirm.']],
  ['图片里没有日期，未入账。打开 Holo 确认。', ['圖片裡沒有日期，未入賬。打開 Holo 確認。', 'No date found in the image — not booked. Open Holo to confirm.']],
  ['日期不在项目周期内，未入账。打开 Holo 确认。', ['日期不在項目週期內，未入賬。打開 Holo 確認。', 'Date is outside the project period — not booked. Open Holo to confirm.']],
  ['这笔可能已经记过，未自动入账。打开 Holo 确认。', ['這筆可能已經記過，未自動入賬。打開 Holo 確認。', 'This may already be logged — not auto-booked. Open Holo to confirm.']],
  ['快捷指令里的账户已失效，未入账。请修改这条快捷指令。', ['快捷指令裡的賬戶已失效，未入賬。請修改這條快捷指令。', 'The account in this shortcut is no longer valid — not booked. Please update the shortcut.']],
  ['快捷指令里的项目已结束，未入账。请修改这条快捷指令。', ['快捷指令裡的項目已結束，未入賬。請修改這條快捷指令。', 'The project in this shortcut has ended — not booked. Please update the shortcut.']],
  ['匹配到多个项目，未入账。打开 Holo 确认。', ['匹配到多個項目，未入賬。打開 Holo 確認。', 'Matched multiple projects — not booked. Open Holo to confirm.']],
  ['收入不能挂项目，未入账。打开 Holo 确认。', ['收入不能掛項目，未入賬。打開 Holo 確認。', "Income can't attach to a project — not booked. Open Holo to confirm."]],
  ['识别结果有异常，未入账。打开 Holo 确认。', ['識別結果有異常，未入賬。打開 Holo 確認。', 'Recognition looks off — not booked. Open Holo to confirm.']],
  ['识别服务需要更新，未自动入账。打开 Holo 手动确认这笔。', ['識別服務需要更新，未自動入賬。打開 Holo 手動確認這筆。', 'Recognition service needs an update — not auto-booked. Open Holo to confirm it manually.']],
  ['这笔需要确认，未自动入账。打开 Holo 复核。', ['這筆需要確認，未自動入賬。打開 Holo 複核。', 'This one needs confirmation — not auto-booked. Open Holo to review.']],
  ['这是转账/还款，属于资金流转，不计入收支。', ['這是轉賬/還款，屬於資金流轉，不計入收支。', "This is a transfer/repayment — money movement, not income or expense."]],
  ['订单还没支付。支付完成后再试一次。', ['訂單還沒支付。支付完成後再試一次。', "This order isn't paid yet. Try again after payment."]],
  ['支付没有完成或已取消，不记账。', ['支付沒有完成或已取消，不記賬。', "Payment didn't complete or was cancelled — nothing to log."]],
  ['这是外币消费，目前只支持人民币记账。', ['這是外幣消費，目前只支持人民幣記賬。', 'This is a foreign-currency purchase. Only CNY is supported for now.']],
  ['这张图里没有能记账的内容。', ['這張圖裡沒有能記賬的內容。', 'Nothing to log in this image.']],
  ['没认出可靠的金额，没有入账。截图仍在照片里，可以拍清楚些再试。', ['沒認出可靠的金額，沒有入賬。截圖仍在照片裡，可以拍清楚些再試。', "Couldn't read a reliable amount — not booked. The screenshot is still in Photos; retake a clearer shot and try again."]],
  ['这张图不适合记账，未入账。', ['這張圖不適合記賬，未入賬。', "This image isn't something to log — nothing booked."]],
  ['网络不可用，未入账。截图仍在照片里，可稍后重试。', ['網絡不可用，未入賬。截圖仍在照片裡，可稍後重試。', 'Network unavailable — not booked. The screenshot is still in Photos; retry later.']],
  ['今天的识别次数用完了，明天再试。', ['今天的識別次數用完了，明天再試。', "Today's recognition quota is used up. Try again tomorrow."]],
  ['服务暂时不可用，未入账。截图仍在照片里，可稍后重试。', ['服務暫時不可用，未入賬。截圖仍在照片裡，可稍後重試。', 'Service temporarily unavailable — not booked. The screenshot is still in Photos; retry later.']],
  ['已取消，未入账。', ['已取消，未入賬。', 'Cancelled — nothing booked.']],
  ['请先打开 Holo 完成设置', ['請先打開 Holo 完成設置', 'Please open Holo to finish setup first']],
  ['请先打开 Holo 完成设置。', ['請先打開 Holo 完成設置。', 'Please open Holo to finish setup first.']],
  ['请先打开 Holo 创建账户', ['請先打開 Holo 創建賬戶', 'Please open Holo to create an account first']],
  ['记账没有成功，请重试', ['記賬沒有成功，請重試', 'Booking failed — please try again']],
  ['记账没有成功', ['記賬沒有成功', "Booking didn't go through"]],
  ['已记账', ['已記賬', 'Booked']],
  ['这张图已经记过', ['這張圖已經記過', 'This image was already logged']],
  ['有一笔账需要你确认', ['有一筆賬需要你確認', 'One entry needs your confirmation']],
  ['金额 %@ 没有自动入账，点按查看。', ['金額 %@ 沒有自動入賬，點按查看。', "Amount %@ wasn't auto-booked. Tap to review."]],
  ['已记 ¥%@', ['已記 ¥%@', 'Booked %@']],
  ['（默认）', ['（預設）', ' (default)']],
  [' · 无项目', [' · 無項目', ' · No project']],

  // ---- 设置页（§11）----
  ['图片自动记账', ['圖片自動記賬', 'Auto Log from Images']],
  ['在支付成功页长按操作按钮，系统截屏交给 Holo 识别：金额、商户、日期、支付方式。金额状态可靠时自动入账并通知你；不可靠时不乱记，等你确认。', ['在支付成功頁長按操作按鈕，系統截屏交給 Holo 識別：金額、商戶、日期、支付方式。金額狀態可靠時自動入賬並通知你；不可靠時不亂記，等你確認。', 'Long-press the Action Button on a payment page and the system hands the screenshot to Holo: amount, merchant, date, payment method. Reliable entries are booked automatically and you get notified; unreliable ones are held for your confirmation instead of being logged wrongly.']],
  ['图片压缩去位置信息后上传识别，识别完即弃', ['圖片壓縮去位置資訊後上傳識別，識別完即棄', 'Images are compressed with location stripped, uploaded for recognition, then discarded right after.']],
  ['当前授权', ['當前授權', 'Authorization']],
  ['已开启', ['已開啟', 'On']],
  ['未开启', ['未開啟', 'Off']],
  ['识别后发通知', ['識別後發通知', 'Notify after recognition']],
  ['不开通知也不影响记账：快捷指令运行完会直接显示结果。', ['不開通知也不影響記賬：快捷指令運行完會直接顯示結果。', 'Notifications are optional: the shortcut always shows the result when it finishes.']],
  ['需要你确认的账', ['需要你確認的賬', 'Awaiting your confirmation']],
  ['待复核', ['待複核', 'To Review']],
  ['三步开启（约 1 分钟）', ['三步開啟（約 1 分鐘）', 'Set up in three steps (~1 min)']],
  ['截图自动记账', ['截圖自動記賬', 'Screenshot auto-log']],
  ['快捷指令 App 新建：①加「截屏」动作 ②加「Holo · 识别图片并记账」③长按动作里的「图片」参数，在弹出菜单中选「截屏」（关键一步，否则运行时会要你选图）。也可固定账户或项目。', ['快捷指令 App 新建：①加「截屏」動作 ②加「Holo · 識別圖片並記賬」③長按動作裡的「圖片」參數，在彈出選單中選「截屏」（關鍵一步，否則運行時會要你選圖）。也可固定賬戶或項目。', 'In Shortcuts: 1) add Take Screenshot 2) add Holo · Recognize & Log a Receipt 3) touch-and-hold the Image parameter of the Holo action and pick Screenshot in the popup menu (essential, otherwise it asks you to pick an image at run time). You can also fix an account or project.']],
  ['拍小票自动记账', ['拍小票自動記賬', 'Receipt photo auto-log']],
  ['快捷指令 App 新建：①加「拍照」动作 ②加「Holo · 识别图片并记账」③长按「图片」参数在菜单中选「拍照」。适合纸质小票。', ['快捷指令 App 新建：①加「拍照」動作 ②加「Holo · 識別圖片並記賬」③長按「圖片」參數在選單中選「拍照」。適合紙質小票。', 'In Shortcuts: 1) add Take Photo 2) add Holo · Recognize & Log a Receipt 3) touch-and-hold the Image parameter and pick Take Photo in the popup menu. Great for paper receipts.']],
  ['绑定操作按钮 / 轻点背面', ['綁定操作按鈕 / 輕點背面', 'Bind Action Button / Back Tap']],
  ['系统设置 → 操作按钮（或 触控 → 轻点背面）→ 选「快捷指令」→ 选上面建好的指令。最后一步需要你亲自设置。', ['系統設定 → 操作按鈕（或 觸控 → 輕點背面）→ 選「快捷指令」→ 選上面建好的指令。最後一步需要你親自設置。', 'Settings → Action Button (or Touch → Back Tap) → Shortcuts → pick the shortcut above. The last step must be done by you.']],
  ['建议先用「安全时自动记账」；想每笔都先确认，可在指令的「处理方式」里改成「始终先确认」。', ['建議先用「安全時自動記賬」；想每筆都先確認，可在指令的「處理方式」裡改成「始終先確認」。', 'Start with "Auto-book when safe"; switch the shortcut\'s mode to "Always confirm first" if you prefer to confirm every entry.']],
  ['最近自动记账结果', ['最近自動記賬結果', 'Recent auto-log results']],
  ['成功记录可在 10 分钟内撤销；待复核证据 7 天后自动清理。', ['成功記錄可在 10 分鐘內撤銷；待複核證據 7 天後自動清理。', 'Booked entries can be undone within 10 minutes; review evidence is purged automatically after 7 days.']],

  // ---- 待复核列表与详情（§25.2）----
  ['没有需要复核的账。', ['沒有需要複核的賬。', 'Nothing to review.']],
  ['超过 7 天未处理的复核项会自动清理，不会入账。', ['超過 7 天未處理的複核項會自動清理，不會入賬。', 'Review items older than 7 days are cleaned up automatically — they are never booked.']],
  ['多笔交易', ['多筆交易', 'Multiple transactions']],
  ['金额不确定', ['金額不確定', 'Amount uncertain']],
  ['收支方向不确定', ['收支方向不確定', 'Direction uncertain']],
  ['支付状态不确定', ['支付狀態不確定', 'Payment status uncertain']],
  ['图片里没有日期', ['圖片裡沒有日期', 'No date in the image']],
  ['可能已经记过一笔', ['可能已經記過一筆', 'May already be logged']],
  ['快捷指令里的账户已失效', ['快捷指令裡的賬戶已失效', 'Shortcut account no longer valid']],
  ['快捷指令里的项目已结束', ['快捷指令裡的項目已結束', 'Shortcut project has ended']],
  ['匹配到多个项目', ['匹配到多個項目', 'Multiple projects matched']],
  ['日期不在项目周期内', ['日期不在項目週期內', 'Date outside the project period']],
  ['识别结果有异常', ['識別結果有異常', 'Recognition looks off']],
  ['识别服务需要更新', ['識別服務需要更新', 'Recognition service needs an update']],
  ['需要确认', ['需要確認', 'Needs confirmation']],
  ['确认这笔账', ['確認這筆賬', 'Confirm This Entry']],
  ['这笔账需要你确认。', ['這筆賬需要你確認。', 'This entry needs your confirmation.']],
  ['图里有多笔交易，先确认这一笔，其余请在账本手动记。', ['圖裡有多筆交易，先確認這一筆，其餘請在賬本手動記。', 'Multiple transactions in the image — confirm this one first, then add the rest manually in the ledger.']],
  ['金额没认准，请核对。', ['金額沒認準，請核對。', 'The amount may be off — please double-check.']],
  ['收支方向不确定，请选择。', ['收支方向不確定，請選擇。', 'Direction uncertain — please choose.']],
  ['支付状态不确定。', ['支付狀態不確定。', 'Payment status uncertain.']],
  ['图片里没有日期，请选择记账日期。', ['圖片裡沒有日期，請選擇記賬日期。', 'No date in the image — please pick the booking date.']],
  ['可能已经记过一笔，请核对后再确认。', ['可能已經記過一筆，請核對後再確認。', 'This may already be logged — double-check before confirming.']],
  ['快捷指令里固定的账户已失效，请重新选择账户，并更新那条快捷指令。', ['快捷指令裡固定的賬戶已失效，請重新選擇賬戶，並更新那條快捷指令。', 'The fixed account in the shortcut is no longer valid — pick an account again and update that shortcut.']],
  ['快捷指令里固定的项目已结束，请重新选择，并更新那条快捷指令。', ['快捷指令裡固定的項目已結束，請重新選擇，並更新那條快捷指令。', 'The fixed project in the shortcut has ended — pick again and update that shortcut.']],
  ['匹配到多个项目，请手动选择。', ['匹配到多個項目，請手動選擇。', 'Multiple projects matched — please pick one.']],
  ['日期不在项目周期内，确认后仍会挂到该项目。', ['日期不在項目週期內，確認後仍會掛到該項目。', 'The date is outside the project period; it will still attach if you confirm.']],
  ['识别结果有异常，请人工核对。', ['識別結果有異常，請人工核對。', 'Recognition looks off — please verify manually.']],
  ['识别服务需要更新，请核对字段。', ['識別服務需要更新，請核對欄位。', 'Recognition service needs an update — please verify the fields.']],
  ['票面金额原文', ['票面金額原文', 'Amount text on receipt']],
  ['金额与收支方向', ['金額與收支方向', 'Amount & Direction']],
  ['方向', ['方向', 'Direction']],
  ['账户与项目', ['賬戶與項目', 'Account & Project']],
  ['备注', ['備註', 'Note']],
  ['确认记账', ['確認記賬', 'Confirm & Book']],
  ['放弃', ['放棄', 'Discard']],
  ['保存失败：%@', ['保存失敗：%@', 'Failed to save: %@']],
  ['复核入账 ¥%@', ['複核入賬 ¥%@', 'Reviewed & booked %@']],
  ['这条待复核已处理或已过期', ['這條待複核已處理或已過期', 'This review item was already handled or has expired']],
  ['这条结果已过期清理', ['這條結果已過期清理', 'This result has expired and been cleaned up']],

  // ---- 快捷指令确认卡 + 复核页重做（2026-09-15 icost 形态）----
  ['计入账单', ['計入賬單', 'Log It']],
  ['不记了', ['不記了', "Don't Log"]],
  ['科目', ['科目', 'Category']],
  ['已按你的记账习惯自动预填，可点改', ['已按你的記賬習慣自動預填，可點改', 'Pre-filled from your logging habits — tap to change']],
  ['本机暂存的识别证据，确认或放弃后删除', ['本機暫存的識別證據，確認或放棄後刪除', 'Recognition evidence stored on this device only — deleted after you confirm or discard']],
  ['识别信息不完整，请核对后保存。', ['識別資訊不完整，請核對後保存。', 'Recognition info is incomplete — please double-check before saving.']],
  ['确认记这笔账：%@', ['確認記這筆賬：%@', 'Log this entry: %@']],
  ['这笔需要你确认', ['這筆需要你確認', 'Needs your confirmation']],
  ['按图匹配', ['按圖匹配', 'From image']],
  ['固定项目', ['固定項目', 'Fixed project']],
  ['这笔已经处理过了。', ['這筆已經處理過了。', 'This entry was already handled.']],
  ['金额无效，请打开 Holo 手动确认这笔。', ['金額無效，請打開 Holo 手動確認這筆。', "Invalid amount — please confirm this entry manually in Holo."]],
  ['确认卡放弃', ['確認卡放棄', 'Discarded from confirmation card']],
  ['商户', ['商戶', 'Merchant']],

  // ---- 结果行（§25.4）----
  ['撤销这笔刚记的账？', ['撤銷這筆剛記的賬？', 'Undo this just-booked entry?']],
  ['撤销这笔', ['撤銷這筆', 'Undo This Entry']],
  ['已生成待复核项，未入账', ['已生成待複核項，未入賬', 'Review item created — not booked']],
  ['非账单图片', ['非賬單圖片', 'Not a billable image']],
  ['未知原因', ['未知原因', 'Unknown reason']],
  ['已撤销', ['已撤銷', 'Undone']],
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
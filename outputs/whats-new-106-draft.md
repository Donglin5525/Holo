# Holo 1.0.6 App Store 更新说明（草稿，待东林拍板）

> 本版 = 1.0.5 全部内容 + 1.0.6 修复，合并为一个版本提交审核（1.0.5 从未单独上架，App Store 同时只允许一个待审版本）。

## 版本 A（叙事流，推荐）

这版我们把「记账」变得更快：看到小票、订单截图，直接发给 Holo 识别，金额、分类自动填好，你确认一下就入账，不用再手动敲。

健康页新增运动报告：每一次跑步、骑行都有独立的完整记录，时长、距离、心率一目了然；健康首页也按「睡眠优先」重新梳理了阅读动线。

「今天」看板全面升级：首页光球焕新，行动优先的布局让「现在最该做什么」更快有答案。

AI 建任务更靠谱：说「9月20日」就是 9月20日，不再识成今天；一句话里交代的好几个提醒时间，现在都能稳稳落上。

想法更好用：点正文直接进编辑器，长按选中复制恢复正常，卡片一点原地展开全文；桌面小组件排版也更整齐了。

稳定性大幅提升——修复了点开 HoloAI 闪退、首次安装可能卡在启动页、删除习惯闪退等多个问题。

## 版本 B（要点流，备选）

· 全新图片快捷记账：小票/截图发给 Holo，识别后确认即入账
· 运动会话报告上线：每段运动独立成篇；健康首页睡眠优先重排
· 「今天」看板升级：光球焕新，行动优先
· AI 建任务更准：日期不再识错，一句话多提醒全支持
· 想法体验优化：点正文进编辑器、长按复制修复、原地展开全文
· 小组件排版修复；稳定性大幅提升，修复多处闪退

---

## 提审信息备忘

- 版本号：1.0.6 / build 27（线上现为 1.0.4 / build 26，1.0.5 未单独上架、跳号无影响）
- 本版范围（东林 9-19 拍板）：仅含 1.0.6 分支已提交的 27 项（含 1.0.5 切割遗留的图片快捷记账）；目标共创整批切 1.0.7（含 CloudKit 两新表部署，届时需真机上报+生产部署）；goalWorkshopV1 生产开关已恢复关闭
- 后端：无需发版（意图提示词 v31、goal_workshop 均已部署生产；goalWorkshopV1 开关保持关，与本版 iOS 不带目标共创正好匹配）
- 权限：无新增（Info.plist / entitlements 与 1.0.4 一致），无需更新审核备注
- 截图：建议沿用 v5 素材（1.0.4 在用）；今日看板/想法编辑器有视觉变化，如想换图需在 ASC 重新上传
- 关键词/推广文本：建议沿用 1.0.4 定稿不动
- 收口时注意：版本号收口提交（1.0.4/26 收口 795dc1bac）没合回主线，1.0.6 收口要一并补：① 版本号 1.0.3/25 → 1.0.6/27；② CHANGELOG 补 1.0.4 漏合回的五条（新用户激活/报告提问分享/固定支出落账/想法大卡/相册受限）+ 1.0.6 章节整理

---

## 终稿（2026-09-19，三语，格式对齐 1.0.4 实稿；每语言一块：先推广文本后更新说明）

### 简体中文（zh-Hans）

**推广文本：**

拍下小票，账就记好了。图片快捷记账上线：小票、订单截图发给 Holo，金额分类自动填好，确认即入账。运动报告独立成篇，健康首页睡眠优先。这版更快、更稳。

**更新说明：**

Holo 1.0.6：拍下小票就记账，AI 更靠谱，App 更稳。

【图片快捷记账】看到小票、订单截图，直接发给 Holo 识别：金额、分类自动填好，你确认一下就入账；在 HoloAI 对话里发图同样能记。

【运动报告上线】每一次跑步、骑行都独立成篇，时长、距离、心率一目了然；健康首页按「睡眠优先」重新梳理，打开先看最重要的。

【「今天」看板升级】首页光球焕新，行动优先的布局让「现在最该做什么」更快有答案。

【AI 建任务更准】说「9月20日」就是 9月20日，不再识成今天；一句话里交代的多个提醒时间，都能稳稳落上。

【想法更好用】点正文直接进编辑器，长按选中复制恢复正常；卡片一点原地展开全文，不跳页；桌面小组件排版更整齐。

【更稳定】修复点开 HoloAI 闪退、首次安装可能卡在启动页、删除习惯闪退等多个问题。

### 繁體中文（zh-Hant）

**推廣文字：**

拍下小票，帳就記好了。圖片快捷記帳上線：小票、訂單截圖傳給 Holo，金額分類自動填好，確認即入帳。運動報告獨立成篇，健康首頁睡眠優先。這版更快、更穩。

**更新說明：**

Holo 1.0.6：拍下小票就記帳，AI 更可靠，App 更穩。

【圖片快捷記帳】看到小票、訂單截圖，直接傳給 Holo 辨識：金額、分類自動填好，你確認一下就入帳；在 HoloAI 對話裡傳圖同樣能記。

【運動報告上線】每一次跑步、騎行都獨立成篇，時長、距離、心率一目瞭然；健康首頁按「睡眠優先」重新梳理，打開先看最重要的。

【「今天」看板升級】首頁光球煥新，行動優先的版面讓「現在最該做什麼」更快有答案。

【AI 建任務更準】說「9月20日」就是 9月20日，不再判成今天；一句話裡交代的多個提醒時間，都能穩穩設定好。

【想法更好用】點內文直接進編輯器，長按選取複製恢復正常；卡片一點原地展開全文，不跳頁；桌面小工具排版更整齊。

【更穩定】修復點開 HoloAI 閃退、首次安裝可能卡在啟動頁、刪除習慣閃退等多個問題。

### English (en-US)

**Promotional Text:**

Snap a receipt and it's recorded. Send a screenshot to Holo, and the amount and category are filled in — just confirm. Plus per-workout reports and a sleep-first health page.

**What's New:**

Holo 1.0.6: snap a receipt to log it, a sharper AI, and a steadier app.

- [Photo expense tracking] See a receipt or order screenshot? Send it to Holo: the amount and category are filled in for you, then just confirm. Works in HoloAI chat too.
- [Workout reports] Every run and ride gets its own session record — duration, distance, heart rate at a glance. The health page now leads with sleep.
- ["Today" board, upgraded] A refreshed home orb and an action-first layout, so "what to do next" is answered faster.
- [Smarter task creation] Say "Sep 20" and it lands on Sep 20 — no longer parsed as today. Multiple reminders in one sentence all stick.
- [Better thoughts] Tap a note's body to jump straight into editing, long-press selection and copy work again, and long notes expand in place. Widgets are tidier too.
- [More stable] Fixed crashes when opening HoloAI, possible stuck first launches on fresh installs, crashes when deleting habits, and more.

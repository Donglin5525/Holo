# App Store 截图候选方案

这两套截图都基于 Debug 模拟器中的可复现演示数据，尚未上传 App Store Connect。

## A：越来越懂你

主叙事是「Holo 会持续理解你的生活」：统一上下文 → 记忆长廊 → 记忆萃取 → 回答引用记忆 → 洞察变成行动。

1. 一个 Holo，装下你的整段生活 —— 记账、待办、习惯、想法与健康，汇入同一个上下文
2. 说一句，Holo 就能帮你做完 —— 记账、创建任务、完成打卡，一次说清
3. 你的生活，随时可以回看 —— 记忆长廊把每天发生的事，串成可探索的时间线
4. Holo 会从记录里提炼出你的节奏 —— 候选记忆带着证据出现，由你决定要不要记住
5. 你用得越久，Holo 越懂你 —— 回答引用你的真实记忆，而不是泛泛而谈
6. 让理解，变成下一步 —— 从洞察继续追问、创建任务或调整习惯

## B：每天更清楚

主叙事是「Holo 让每天更容易安排」：今日总览 → 一句话完成多件事 → HoloAI 深度分析 → 财务趋势 → 生活回看 → 下一步行动。

1. 把今天的生活放在一页 —— 任务、日程、习惯、预算和心情，一眼看清
2. 说一句，记录和行动一起完成 —— 自然表达也能完成记账、待办和打卡
3. 用 HoloAI，看懂这个月 —— 把支出、习惯、待办和想法，汇成有证据的洞察
4. 钱花在哪，趋势会说话 —— 余额、收支与分类变化，用一张图看懂
5. 每一天，都能回到发生的现场 —— 消费、任务、习惯和想法，按时间重新串联
6. 从看见变化，到马上行动 —— AI 把数据变成问题、计划和下一步

目录结构：

- `a/iphone-6.9/final` 与 `a/ipad-13/final`
- `b/iphone-6.9/final` 与 `b/ipad-13/final`

渲染命令示例：

```sh
xcrun swift scripts/render_app_store_screenshots.swift "$PWD" a
xcrun swift scripts/render_app_store_screenshots.swift "$PWD" a ipad
xcrun swift scripts/render_app_store_screenshots.swift "$PWD" b
xcrun swift scripts/render_app_store_screenshots.swift "$PWD" b ipad
```

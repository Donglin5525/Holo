# Holo App Store Review Notes 与 ASO 元数据草稿

更新时间：2026-08-25

## 使用方式

这份文档用于 App Store Connect 的版本信息、审核备注和截图文案准备。

## 1.0（21）拒审后重新提交补充说明

本次重新提交针对 1.0（18）的两项拒审问题：

- **Guideline 2.1(b)**：已修复「个人 → Holo Plus → 升级 Holo Plus」按钮无响应。付费墙现在由当前可见的会员中心直接展示，不再跨越系统 sheet 层级；请在 Sandbox 环境加载 `Holo Plus Monthly` 并测试购买或恢复购买。
- **Guideline 2.5.1**：健康模块保留用户易懂的名称「健康」，界面明确展示「连接 Apple Health」「授权后只读同步步数、睡眠和活动数据」及「健康数据由 Apple Health 提供」。请按「首页 → 健康 → 连接 Apple Health」查看；审核备注需附真机录屏链接。

建议回复 App Review：

```text
Hello App Review Team,

Thank you for the feedback. We have addressed both issues in version 1.0 (build 21).

1. Guideline 2.1(b): We fixed the presentation flow for the Holo Plus paywall. The button at Profile > Holo Plus > Upgrade Holo Plus now opens the paywall directly from the currently visible screen. The subscription price, renewal period, automatic-renewal disclosure, Restore Purchases, Privacy Policy, and Terms of Use are visible on the paywall.

2. Guideline 2.5.1: The Health screen now clearly identifies its Apple Health integration in the user interface. The path is Home > Health > Connect Apple Health. The screen states that Holo reads authorized steps, sleep, stand time, and active time from Apple Health in read-only mode. We have included a physical-device screen recording in App Review Information > Notes: [REPLACE WITH PUBLIC RECORDING URL].

Thank you for reviewing the updated build.
```

提交前必须把 `[REPLACE WITH PUBLIC RECORDING URL]` 换成无需登录即可访问的真机录屏链接，并在 App Review Information 的 Notes 同步保存。

## ASO 定位

### 核心搜索意图

Holo 首版不应只打“AI”或“个人数据资产”这种用户感知弱、搜索意图不稳定的词。更稳的 ASO 入口是“个人效率 + 生活记录 + 多模块管理”。

优先覆盖的搜索场景：

- 用户想找记账工具：记账、账本、收支、财务记录
- 用户想找任务工具：待办、清单、事项、计划
- 用户想找习惯工具：习惯、自律、目标
- 用户想找记录工具：笔记、备忘录、灵感、生活记录
- 用户想找复盘工具：日历、复盘、时间管理、个人管理
- 用户想找智能辅助：AI助手、智能整理

### ASO 写法原则

- App 名称和副标题优先放高搜索意图词，不写抽象品牌宣言。
- 关键词字段避免重复 App 名称和副标题中已经出现的词。
- 描述首屏先讲用户能得到什么，不先讲架构、长期记忆或个人数据资产。
- 不写第三方 AI 品牌名，避免中国区和审核风险。
- 不承诺医疗、投资、法律等专业建议。

## App Store 元数据草稿

### App 名称

推荐：

Holo - 记账待办习惯助手

备选：

Holo - 生活记录与AI助手

说明：推荐名优先覆盖“记账、待办、习惯、助手”这组高意图词，比只写 Holo 更利于冷启动搜索曝光。若你更在意品牌纯净度，可用备选名，但搜索覆盖会弱一些。

### 副标题

推荐：

日历复盘、笔记健康与AI整理

备选：

记录生活、管理目标和灵感

说明：推荐副标题补足“日历、复盘、笔记、健康、AI整理”。这些词不和推荐 App 名称重复，能扩大搜索覆盖。

### 宣传文本

记账、待办、习惯、笔记和健康状态放在一个地方。Holo 用日历和 AI 整理帮你看清每天发生了什么，也看见长期变化。

### 简短描述

Holo 是一款生活记录和个人管理工具，把记账、待办、习惯、笔记、日历复盘和健康状态放在一起，并用 AI 帮你整理线索、回看变化。

### 完整描述

每天都有很多事发生：花了多少钱、完成了什么、习惯有没有坚持、身体状态怎么样、脑子里冒出了哪些想法。Holo 帮你把这些零散记录放在一个清晰的生活工作台里。

你可以用 Holo 记账、管理待办、追踪习惯、记录笔记和灵感，也可以通过 Apple Health 授权查看步数、睡眠、站立和运动时长。Holo 会用日历和记忆长廊帮你复盘每天的变化，而不是让记录散落在不同 App 里。

如果你开启 AI 数据处理授权，HoloAI 可以帮你整理记录、识别分类、总结近期状态，并把一些值得回看的线索沉淀下来。AI 生成内容仅供参考，不构成医疗、财务、法律或投资建议。

你可以用 Holo 做什么：

- 记账与收支记录：记录日常消费、收入、分类和账户。
- 待办与清单管理：整理任务、计划和事项。
- 习惯追踪：记录习惯完成情况，观察坚持节奏。
- 笔记与灵感记录：保存想法、观点、标签和引用。
- 日历复盘：用周历和月历回看每天发生了什么。
- 记忆长廊：把长期变化整理成更容易理解的回顾。
- 健康状态：只读展示 Apple Health 授权后的步数、睡眠、站立和运动数据。
- AI 整理：在你授权后，辅助分类、总结和发现记录之间的联系。
- iCloud 同步：通过用户自己的 iCloud 私有数据库在设备间同步 Holo 本地记录。
- 数据管理：应用内提供隐私政策、用户协议和账号/数据删除入口。

隐私与数据：

- Holo 不使用第三方广告追踪。
- Holo 不会主动保存你发送给 AI 的原始请求正文、语音音频或完整上下文作为用户资料。
- 为保障服务安全、限流和故障排查，Holo 后端会保存最小化技术日志或摘要信息，并按后台配置定期清理。
- Holo 不会将从 Apple HealthKit 读取的原始健康数据写入或同步到 Holo 的 iCloud 数据库；使用需要健康上下文的 AI 功能时，必要的健康摘要会在用户同意 AI 数据处理后发送至 Holo 后端和第三方 AI 服务。

### 关键词

推荐关键词字段：

账本,收支,账单,消费,预算,收入,支出,账户,分类,清单,事项,计划,目标,自律,打卡,提醒,备忘录,灵感,想法,生活记录,效率,时间管理,个人管理,每日记录,周计划,月总结,心情,睡眠,运动

备选关键词字段：

账本,收支,账单,消费,预算,收入,支出,账户,分类,清单,事项,计划,目标,自律,打卡,提醒,备忘录,灵感,想法,生活记录,效率,时间管理,个人管理,每日记录,周计划,月总结,心情,生活管理

说明：如果使用推荐 App 名称和副标题，关键词字段不要再重复“记账、待办、习惯、日历、复盘、笔记、健康、AI、助手、整理”。推荐版 97 字符，覆盖更完整；备选版 96 字符，去掉“睡眠、运动”，适合想进一步降低健康类审核预期时使用。

### 版本更新说明

首次提交 App Store：记录记账、待办、习惯、笔记和健康状态，支持日历复盘、记忆长廊和 AI 整理。

### Support URL

https://holoapp.cn/support

### Privacy Policy URL

https://holoapp.cn/privacy

### Copyright

Copyright © 2026 Holo. All rights reserved.

### 分类建议

主分类：Productivity

副分类：Health & Fitness 或 Lifestyle

ASO 建议：主分类选 Productivity，副分类选 Lifestyle。Holo 的核心购买理由是个人管理、记录和复盘，不是专业健康工具。这样既贴近搜索意图，也能降低 Health & Fitness 审核语境下的医疗化预期。

### 年龄分级建议

建议按 4+ 或 9+ 预填，最终以 App Store Connect 年龄分级问卷为准。注意 AI 生成内容、用户输入内容和健康/财务提示不要在截图和描述里呈现高风险内容。

## 截图建议

建议准备 6 张 iPhone 截图。截图标题要像搜索结果里的广告语，直接说用户收益，不要写功能说明书。

1. 把生活记录放在一个地方  
   画面：首页总览，展示记账、待办、习惯、健康、笔记入口。

2. 记账、待办、习惯一起管理  
   画面：任务或首页模块，体现多模块个人管理。

3. 用日历复盘每天发生了什么  
   画面：记忆长廊周历/月历与观察摘要。

4. 看见消费、习惯和状态变化  
   画面：财务统计或习惯趋势，使用虚构数据。

5. 连接 Apple Health 查看健康状态  
   画面：健康页，只展示只读授权后的状态，不写医疗化承诺。

6. 让 AI 帮你整理记录线索  
   画面：HoloAI 对话或 AI 整理入口，不出现第三方 AI 品牌名。

截图数据必须使用虚构数据，不要出现真实姓名、真实账单、真实健康记录或真实联系方式。

### 截图副标题备选

- 日常记录不用散在多个 App
- 从今天的记录看见长期变化
- 任务、习惯、账本和笔记一起复盘
- AI 只在你授权后处理必要上下文
- Apple Health 数据只读展示
- 隐私、授权和删除入口都在设置里

## App Review Notes 草稿

### 1. Screen Recording on a Physical Device

请在审核备注中提供一条真机录屏链接（非模拟器、无设备外框），覆盖以下路径；如果 App Store Connect 当前版本不要求录屏，也应保留这条演示材料，便于审核员快速复现核心功能。

建议录屏内容：

- 从冷启动打开 Holo。
- 使用 Sign in with Apple 登录。
- 进入首页查看财务、习惯、待办、观点和健康入口。
- 打开 HoloAI，开启 AI 数据处理授权，发送一条示例请求。
- 展示 Apple Health 授权入口和健康状态页面。
- 打开记忆长廊日历视图。
- 进入设置，展示隐私政策、用户协议和“删除账号与 Holo 数据”入口。

### 2. App Purpose Description

Holo is a personal productivity and life logging app. It helps users record expenses, tasks, habits, notes, and health status, then review daily activity and long-term patterns through calendar views, memory insights, and optional AI-assisted organization.

The app is intended for personal organization and self-reflection. It does not provide medical diagnosis, investment advice, legal advice, or other professional advice.

### 3. Access Instructions and Test Credentials

Holo supports Sign in with Apple. Reviewers can sign in with Apple directly.

Suggested review path:

1. Launch the app.
2. Sign in with Apple.
3. Use the main dashboard to open Finance, Habits, Tasks, Thoughts, Health, and Memory Gallery.
4. Open HoloAI. If the consent sheet appears, enable AI data processing there; the same control is available under Settings -> HoloAI Data Authorization.
5. To test Health features, grant Apple Health read access if health data exists on the device. If no Health data is available, the app shows an empty/unauthorized state.
6. Open Settings -> Legal & Privacy to view Privacy Policy and Terms of Use.
7. Open Settings -> Account & Data -> Delete Account and Holo Data to review the deletion flow.

No separate username/password demo account is required because the app uses Sign in with Apple.

### 4. External Services List

Holo uses the following external services:

- Sign in with Apple: account authentication.
- Apple CloudKit/iCloud: syncing Holo local records across the user's own devices through the user's private iCloud database.
- Apple HealthKit: read-only access to steps, sleep, stand time, and active time after user permission.
- HoloBackend at `https://api.holoapp.cn`: API gateway for AI, ASR, prompt routing, rate limiting, service diagnostics, and safety controls.
- Third-party AI/ASR providers through HoloBackend, such as Alibaba Cloud Bailian and DeepSeek, for AI responses, data insight generation, classification assistance, and speech-to-text. These services are used only after the user enables AI data processing consent.

Holo does not use third-party advertising or cross-app tracking.

### 5. Regional Differences

The app provides the same core features in all 175 selected regions, including Mainland China. There are no region-specific feature differences in this release.

### 6. Regulated Industry / Health Notes

Holo is not a medical device and does not provide medical diagnosis or treatment recommendations.

Health-related features only display and summarize user-authorized Apple Health data for personal reference. The app does not write to Apple Health, does not modify HealthKit data, does not use health data for advertising or marketing, and does not store raw Apple HealthKit data in Holo's iCloud database.

AI-generated content is for reference only and is not professional medical, financial, or legal advice.

### 7. Privacy and Deletion Notes

The app includes in-app Privacy Policy and Terms of Use under Settings -> Legal & Privacy.

The app includes account and data deletion under Settings -> Account & Data -> Delete Account and Holo Data. This clears local Holo data, attachments, AI memory, cache, Keychain login state, and app-specific UserDefaults. For iCloud-synced Holo records, deletion is propagated by Apple's CloudKit sync when the device is online.

### 8. Non-Obvious Features for Reviewer

- HoloAI requires explicit AI data processing consent before sending necessary input/context to external AI or speech services.
- If the user separately enables automatic memory formation, Holo may analyze necessary structured summaries in the background. Turning this user control off stops automatic AI extraction. Automatic observation jobs do not request iOS Continued Processing.
- Health features require Apple Health authorization and may show empty states on devices without Health data.
- Memory Gallery insights may depend on user-created records and may be sparse on a fresh install.
- iCloud sync depends on the reviewer being signed in to iCloud on the test device.

### 9. iOS Continued Processing

On iOS 26 or later, a deep analysis explicitly started by the reviewer from HoloAI may request the system Continued Processing capability. This lets the user-initiated task make progress after returning to the Home Screen, switching apps, or locking the device when iOS accepts the request.

- The request is submitted only in direct response to the user's HoloAI analysis action and only after AI data processing consent.
- iOS presents system-managed progress with a generic Holo title and gives the user a cancellation control.
- If the system declines or terminates processing, Holo saves a checkpoint and safely resumes when the app becomes available again.
- Force-quitting Holo does not promise continued execution.
- Automatic Observer and scheduled jobs are explicitly excluded from Continued Processing.

Suggested verification on an iOS 26 device:

1. Open HoloAI and grant AI data processing consent if requested.
2. Ask a data-analysis question that routes to deep analysis.
3. After the progress state appears, return to the Home Screen or lock the device.
4. Observe the system-managed Holo progress, then return to Holo to view the completed result or saved checkpoint state.

---

## 多语言元数据（二期英文 + 一期繁体，2026-09-05 起草，待东林定稿）

### English (en-US)

**App 名称（≤30 字符，实测 29）：**

Holo - Budget, Tasks & Habits

**副标题（≤30 字符，实测 29）：**

Calendar, notes, health & AI

**宣传文本（170 字符内）：**

Budget, to-dos, habits, notes and health in one place. Holo uses your calendar and AI to help you see what happened each day — and how life shifts over time.

**简短描述：**

Holo is a life journal and personal manager. Track expenses, to-dos, habits, notes, calendar reviews and health stats together — with AI that helps you connect the dots and see long-term change.

**完整描述：**

A lot happens every day: what you spent, what you finished, whether your habits held up, how you slept, and the ideas that crossed your mind. Holo puts those scattered records into one clear life dashboard.

Use Holo to track expenses, manage to-dos, build habits, and capture notes and ideas. With Apple Health permission, view steps, sleep, stand hours and workouts. Holo's calendar and Memory Gallery help you review each day instead of losing records across different apps.

If you enable AI data processing, HoloAI can organize your records, categorize entries, summarize recent status, and surface clues worth revisiting. AI-generated content is for reference only and is not medical, financial, legal or investment advice.

What you can do with Holo:

- Expense tracking: log spending, income, categories and accounts.
- To-dos & lists: organize tasks, plans and errands.
- Habit tracking: record completions and see your streaks.
- Notes & ideas: save thoughts, tags and references.
- Calendar reviews: look back with weekly and monthly views.
- Memory Gallery: long-term change, organized into easy reads.
- Health stats: read-only steps, sleep, stand and workout data from Apple Health.
- AI organization: with your permission, assist categorizing, summarizing and connecting records.
- iCloud sync: your records sync across devices via your own iCloud private database.
- Data controls: privacy policy, terms, and account/data deletion in-app.

Privacy & data:

- Holo uses no third-party ad tracking.
- Holo does not proactively store the raw text, voice audio or full context you send to AI as user profiles.
- For security, rate limiting and troubleshooting, the Holo backend keeps minimized technical logs or summaries, purged on schedule.
- Raw health data from Apple HealthKit is never written to or synced with Holo's iCloud database; when AI features need health context, a minimal health summary is sent to the Holo backend and third-party AI services only after you consent to AI data processing.

**关键词（100 字符内，实测 98）：**

budget,expense,tracker,todo,task,habit,checklist,journal,notes,diary,calendar,health,sleep,steps,goal,reminder,life,daily,weekly,review

### 繁體中文 (zh-Hant)

**App 名稱：**

Holo - 記帳待辦習慣助手

**副標題：**

行事曆回顧、筆記健康與AI整理

**宣傳文本：**

記帳、待辦、習慣、筆記和健康狀態放在一個地方。Holo 用行事曆和 AI 整理幫你看清每天發生了什麼，也看見長期變化。

**簡短描述：**

Holo 是一款生活記錄和個人管理工具，把記帳、待辦、習慣、筆記、行事曆回顧和健康狀態放在一起，並用 AI 幫你整理線索、回看變化。

**完整描述：**

每天都有很多事發生：花了多少錢、完成了什麼、習慣有沒有堅持、身體狀態怎麼樣、腦中冒出了哪些想法。Holo 幫你把這些零散記錄放在一個清晰的生活工作台裡。

你可以用 Holo 記帳、管理待辦、追蹤習慣、記錄筆記和靈感，也可以透過 Apple Health 授權查看步數、睡眠、站立和運動時長。Holo 會用行事曆和記憶長廊幫你回顧每天的變化，而不是讓記錄散落在不同 App 裡。

如果你開啟 AI 資料處理授權，HoloAI 可以幫你整理記錄、識別分類、總結近期狀態，並把一些值得回看的線索沉澱下來。AI 生成內容僅供參考，不構成醫療、財務、法律或投資建議。

你可以用 Holo 做什麼：

- 記帳與收支記錄：記錄日常消費、收入、分類和帳戶。
- 待辦與清單管理：整理任務、計畫和事項。
- 習慣追蹤：記錄習慣完成情況，觀察堅持節奏。
- 筆記與靈感記錄：保存想法、觀點、標籤和引用。
- 行事曆回顧：用週曆和月曆回看每天發生了什麼。
- 記憶長廊：把長期變化整理成更容易理解的回顧。
- 健康狀態：唯讀顯示 Apple Health 授權後的步數、睡眠、站立和運動資料。
- AI 整理：在你授權後，輔助分類、總結和發現記錄之間的聯繫。
- iCloud 同步：透過使用者自己的 iCloud 私人資料庫在裝置間同步 Holo 本地記錄。
- 資料管理：應用內提供隱私政策、使用者協議和帳號/資料刪除入口。

隱私與資料：

- Holo 不使用第三方廣告追蹤。
- Holo 不會主動保存你傳送給 AI 的原始請求正文、語音音訊或完整上下文作為使用者資料。
- 為保障服務安全、限流和故障排查，Holo 後端會保存最小化技術日誌或摘要資訊，並按後台設定定期清理。
- Holo 不會將從 Apple HealthKit 讀取的原始健康資料寫入或同步到 Holo 的 iCloud 資料庫；使用需要健康上下文的 AI 功能時，必要的健康摘要會在使用者同意 AI 資料處理後傳送至 Holo 後端和第三方 AI 服務。

**關鍵詞：**

帳本,收支,帳單,消費,預算,收入,支出,帳戶,分類,清單,事項,計畫,目標,自律,打卡,提醒,備忘錄,靈感,想法,生活記錄,效率,時間管理,個人管理,每日記錄,週計畫,月總結,心情,睡眠,運動

**多语言上架备注：**
1. 英文/繁体截图待批量生成（en + zh-Hant 两套，沿用 zh-Hans 的 seeder 流程）
2. 英文版隐私政策/支持页需要英文页面（合规），待东林确认域名与托管方式
3. 「复盘」台湾译为「回顧/複盤」，此处取「回顧」更口语；「日历→行事曆」「数据→資料」「设置→設定」按台湾惯例

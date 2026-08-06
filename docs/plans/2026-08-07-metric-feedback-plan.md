# P1 实施方案：崩溃监控（MetricKit）+ 用户反馈入口

> 制定时间：2026-08-07
> 分支：release/1.0.0
> 目标：上线后不盲飞——能看到崩溃，用户能找得到你

---

## 背景

首版没有崩溃监控（无 Crashlytics/Sentry/MetricKit），也没有明显的用户反馈入口。
上线后若崩溃，既看不到日志，用户也找不到反馈渠道——等于盲飞。

本方案用**苹果原生 MetricKit**（零第三方依赖）补上监控，用**系统邮件**补上反馈入口。
两者都是改动小、不引入新依赖、对审核友好的方案。

---

## P1-1：MetricKit 崩溃监控

### 为什么选 MetricKit 不选 Crashlytics

| 维度 | MetricKit | Crashlytics |
|------|-----------|-------------|
| 依赖 | 系统自带，零依赖 | 要接 Firebase SDK（重） |
| 隐私审核 | 不引入第三方，对审核友好 | SDK 要在隐私问卷申报 |
| 能抓什么 | 崩溃 + 卡顿 + CPU/内存峰值 | 主要崩溃 |
| 上报方式 | App 本地收集 → 用户主动导出 | 自动上报到 Firebase 后台 |
| 适合阶段 | 首版、用户量小 | 用户量大、需要实时面板时 |

首版 MetricKit 够用。等用户量上来再考虑 Crashlytics。

### MetricKit 的工作原理（用人话说）

MetricKit 是苹果给开发者的「体检报告」。系统会把过去一段时间收集到的崩溃、卡顿等数据打包，**每天定期**交给 App。App 收到后可以存成本地文件，用户反馈时导出发给开发者。

注意：MetricKit **不是实时上报**的——它是按天批量交付。真正的实时性靠的是「用户主动反馈 + 导出日志」这条链路（P1-2 配合）。

### 改动清单

| # | 文件 | 改动 | 量 |
|---|------|------|----|
| ① | 新建 `Services/Diagnostics/HoloMetricManager.swift` | 订阅 MetricKit + 收集 payload + 写本地日志 | ~90 行 |
| ② | 新建 `Services/Diagnostics/HoloDiagnosticLogger.swift` | 日志文件管理（按天滚动 + 导出） | ~60 行 |
| ③ | 改 `HoloApp.swift` | `init()` 里加一行 `HoloMetricManager.shared.start()` | 1 行 |
| ④ | 改 `Views/Settings/SettingsView.swift` | otherSettingsSection 加一行「诊断与反馈」入口 | ~5 行 |

### 设计细节

**HoloMetricManager**（核心）：
- 遵循 `MXMetricManagerSubscriber`
- 订阅三类诊断：`MXCrashDiagnostic`（崩溃）、`MXHangDiagnostic`（卡顿 ≥250ms）、`MXCPUExceptionDiagnostic`（CPU 占用异常）
- `didReceive(_:)` 回调里：把 payload 序列化成可读文本，交给 `HoloDiagnosticLogger` 写文件
- 日志按天一个文件（`holo-diagnostic-2026-08-07.txt`），最多保留 7 天，自动清理

**HoloDiagnosticLogger**（文件管理）：
- 日志目录：App 的 `Application Support/diagnostics/`
- 写入：追加模式，每条带时间戳
- 导出：把目录里所有 `.txt` 打包成单个文本，供邮件分享
- 清理：启动时删除 7 天前的文件

**HoloApp.swift 接入**：
```swift
init() {
    // ... 现有代码 ...
    HoloMetricManager.shared.start()   // ← 新增这一行
}
```

**设置页入口**：
在 `otherSettingsSection` 顶部（DEBUG 区之前）加一行：
```swift
settingsRow(
    icon: "ladybug.circle",
    iconColor: .orange,
    title: "诊断与反馈",
    subtitle: "问题反馈、导出诊断日志"
) {
    showDiagnostics = true
}
```

点击进入一个诊断页（复用 `HealthKitDiagnosticsView` 的布局模式），里面有：
- 「发送反馈邮件」按钮（触发 P1-2 的邮件分享）
- 「查看诊断日志」区域（显示最近的 MetricKit 收集记录）
- 「导出日志」按钮（把诊断日志作为邮件附件）

### 不做的事

- 不接 Crashlytics（首版不需要）
- 不做自动上报到后端（隐私 + 工作量，首版用邮件导出代替）
- 不抓 GPU 诊断、网络诊断（首版只抓最关键的崩溃/卡顿/CPU）

---

## P1-2：用户反馈入口（邮件）

### 设计

用系统自带的 `MFMailComposeViewController`（MessageUI），点击反馈后：
- 预填收件人 `holoappservice@gmail.com`
- 预填主题「Holo 反馈」
- 预填正文：设备型号 + 系统版本 + App 版本 + 可选的诊断日志附件

### 改动清单

| # | 文件 | 改动 | 量 |
|---|------|------|----|
| ① | 新建 `Services/Feedback/HoloFeedbackMailer.swift` | 封装 MFMailComposeViewController + 设备信息收集 | ~70 行 |
| ② | 改 `Views/Settings/SettingsView.swift` | 与 P1-1 共享入口（诊断与反馈页内触发） | 0（合并到 P1-1） |

**HoloFeedbackMailer**：
- `canSendMail()`：检查 `MFMailComposeViewController.canSendMail()`
- `presentMail()`：弹邮件界面，预填收件人/主题/正文
- 正文自动带：`UIDevice.model`、系统版本、App 版本（`Bundle.main`）
- 若用户没配置邮件账户：降级为「复制邮箱地址」提示

**与 P1-1 的关系**：
反馈入口和诊断日志入口合并到**同一个设置页行**（「诊断与反馈」），点进去是一个页面，里面有「发邮件」和「看日志」两个功能。不拆成两个入口，避免设置页太碎。

### 不做的事

- 不做内嵌反馈表单（Web View / 自建表单）——首版邮件够用
- 不做反馈分类标签——首版用邮件主题区分即可

---

## 验证标准

| 验证项 | 方法 |
|--------|------|
| MetricKit 订阅成功 | App 启动无报错，`MXMetricManager.shared.subscribers` 含 HoloMetricManager |
| 崩溃能被记录 | 模拟器上跑测（MetricKit 真机交付有延迟，模拟器可手动触发 `didReceive` 测试） |
| 日志写入成功 | App Support/diagnostics/ 下有按天命名的文件 |
| 邮件能弹出 | 设置页点「诊断与反馈」→ 邮件界面弹出、预填内容正确 |
| 日志能导出 | 邮件附件含诊断日志文件 |

---

## 后端发版

**不需要。** 两个功能都是 iOS 单端，不涉及后端。

---

## 风险

| 风险 | 概率 | 缓解 |
|------|------|------|
| MetricKit 真机交付有延迟（数小时~1天） | 确定 | 这是系统行为，靠 P1-2 邮件反馈补实时性 |
| 模拟器上 MetricKit 不交付数据 | 确定 | 手动构造 payload 测试写入逻辑，真机验证留给 TestFlight |
| 用户没配邮件账户 | 低 | 降级为复制邮箱提示 |

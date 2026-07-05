# Holo App Store Preflight Report

更新时间：2026-07-06

## 结论

当前状态：Conditional Go。

本地 Release 无签名构建已通过，但 App Store Connect 元数据、真机录屏、截图、signed Archive/TestFlight、区域策略和最终隐私标签仍需要提交前补齐。代码侧本轮已把隐私政策口径、AI 数据处理授权和高风险数据处理说明先收紧。

## Rejections Found

### 1. Guideline 2.1 - Review Notes 尚未最终完成

状态：未完成，需人工补材料。

原因：新 app 提交需要提供真机录屏、产品用途、访问步骤、外部服务、区域差异和高敏功能说明。

操作路径：

1. 打开 App Store Connect。
2. 进入 Holo app。
3. 进入当前版本。
4. 打开 App Review Information / Notes。
5. 参考 `docs/app-store/review-notes-and-metadata.md` 填写。
6. 替换真实真机录屏链接。

### 2. Guideline 2.3 - App Store 元数据未能本地核实

状态：未完成，需人工填 ASC。

原因：本机没有 `asc` CLI，仓库也没有本地 metadata 包，无法核实截图、隐私 URL、Support URL、描述、关键词、年龄分级和销售范围。

操作路径：

1. App Store Connect -> My Apps -> Holo。
2. App Store -> App Information。
3. 填 App Name、Subtitle、Category、Content Rights。
4. App Store -> 当前版本 -> Version Information。
5. 填 Description、Keywords、Support URL、Marketing URL、Copyright。
6. App Privacy -> 填隐私标签。

### 3. Guideline 5.1.2 - 第三方 AI 数据处理需要明确同意

状态：本轮已补代码，仍需真机验证。

已做：

- 新增 AI 数据处理授权状态。
- HoloAI 聊天入口未同意时不发送。
- HoloBackend AI 网关调用未同意时不发送。
- HoloBackend ASR 语音识别未同意时不上传音频。
- AI 设置页新增“允许 AI 数据处理”开关。

验证路径：

1. 新装或清理 App 数据。
2. 不开启授权，进入 HoloAI 发送消息，应看到授权提示且不发起 AI 请求。
3. 进入 设置 -> AI 助手 -> 允许 AI 数据处理。
4. 再次使用 HoloAI，应允许请求。
5. 关闭授权，再测试语音转文字和 AI 洞察，应停止外部调用。

### 4. Guideline 5.1.1 - 隐私政策与后端日志口径需一致

状态：本轮已修文案，仍需发布网页版本。

已做：

- 网页隐私政策改为“不主动保存原始请求正文/语音音频/完整上下文作为用户资料”。
- App 内隐私政策同步同一口径。
- 明确服务器会保存最小化技术日志或摘要，用于安全、限流和排障。
- 明确默认不保存完整原文，并按后台配置定期清理。

后续操作：

1. 将 `docs/privacy-policy.html` 发布到 `https://holoapp.cn/privacy`。
2. 确认 App Store Connect 的 Privacy Policy URL 指向最新版本。
3. App Privacy labels 与该文案保持一致。

### 5. Guideline 5.1.3 - HealthKit 与 iCloud 风险需继续真机和数据链路核实

状态：代码口径已收紧，提交前仍需复核。

当前判断：

- HealthKit 读取是用户授权后只读。
- Holo 不写入 Apple Health。
- 健康洞察缓存使用本地 Caches 文件，不进入 Core Data CloudKit 主库。
- Memory Insight 的健康上下文在 Release 默认关闭的 feature flag 下不启用，但提交前仍要确认线上 build 没有手动打开。

操作路径：

1. 检查 Release 环境下 `InsightFeatureFlags.healthContextEnabled` 是否保持默认关闭或明确不写入 CloudKit。
2. 真机授权 Apple Health 后验证健康页面只读展示。
3. 断网和未授权情况下验证不会崩溃。
4. 在 Review Notes 里明确：不写入 HealthKit、不将原始 HealthKit 数据写入 Holo iCloud 数据库、不提供医疗诊断。

## Warnings

### 1. 中国大陆销售范围需要产品决策

风险：如果选择中国大陆，metadata 所有可见 locale 都应避免 `ChatGPT`、`GPT`、`OpenAI`、`Claude`、`Anthropic`、`Gemini` 等第三方 AI 品牌词。

建议：

- 首版若不确定合规材料，优先排除中国大陆。
- 如果必须上中国大陆，metadata 使用“AI 助手”“智能分析”等通用表述，不写具体第三方模型品牌。

### 2. Signed Archive / TestFlight 尚未完成

当前只验证了无签名 Release build。

操作路径：

1. Xcode 打开 `Holo/Holo APP/Holo/Holo.xcodeproj`。
2. Scheme 选 `Holo`。
3. Destination 选 `Any iOS Device`。
4. Product -> Archive。
5. Organizer -> Distribute App -> App Store Connect。
6. 先上传 TestFlight，确认 Apple 静态检查没有新问题。

### 3. 真机截图和录屏未完成

操作路径：

1. 使用真机准备虚构数据。
2. 截图首页、HoloAI、记忆长廊、财务、健康、设置隐私。
3. QuickTime Player -> New Movie Recording -> 选择 iPhone。
4. 录制完整审核路径。
5. 上传到可公开访问链接，填入 Review Notes。

### 4. Support URL 尚未确认

建议页面至少包含：

- 产品名称。
- 联系邮箱：support@holoapp.cn。
- 隐私政策链接。
- 常见问题或“如何删除账号与数据”说明。

## Passed

### 1. Release build

无签名 Release build 已通过。

命令：

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

结果：

```text
BUILD SUCCEEDED
```

### 2. 基础合规能力

已具备：

- Sign in with Apple。
- App 内隐私政策。
- App 内用户协议。
- 删除账号与 Holo 数据入口。
- PrivacyInfo.xcprivacy。
- HealthKit entitlement。
- CloudKit/iCloud entitlement。
- App Group entitlement。
- 默认生产后端 `https://api.holoapp.cn`。

## 提交前最终清单

- [ ] 发布最新 `docs/privacy-policy.html` 到线上隐私政策 URL。
- [ ] 在 App Store Connect 填 Support URL 和 Privacy Policy URL。
- [ ] 确认 App Privacy labels 与实际数据处理一致。
- [ ] 选择是否上中国大陆。
- [ ] 准备真机截图。
- [ ] 准备真机审核录屏链接。
- [ ] 将 `docs/app-store/review-notes-and-metadata.md` 中的 TODO 全部替换。
- [ ] Xcode signed Archive。
- [ ] 上传 TestFlight。
- [ ] 真机完整走查 Sign in with Apple、AI 授权、HoloAI、语音、HealthKit、iCloud、删除账号与数据。
- [ ] 审核期间保持 `https://api.holoapp.cn` 后端稳定在线。


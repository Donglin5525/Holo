# Holo App Store Preflight Report

更新时间：2026-08-25

## 结论

当前状态：**代码侧 Go，提交操作侧 Conditional Go**。

1.0（21）已在本地完成 Release 真机配置无签名构建。1.0（18）的两项拒审问题均有明确处理：Holo Plus 付费墙层级已修复；健康页已在界面中明确标识 Apple Health 及只读用途。真正重新提交前仍必须完成 signed Archive/TestFlight、真机 Sandbox 内购、Apple Health 录屏、App Review Notes 附件与 CloudKit Production schema 部署。

## Rejections Found

### 1. Guideline 2.1(b) - Holo Plus 真机 Sandbox 尚未验收

状态：代码已修复，真机验证待完成。

已修复：会员中心当前可见层级直接展示付费墙，避免嵌套 sheet 与 App 根视图全屏展示冲突。付费墙具备商品名称、价格/周期、自动续订说明、恢复购买、隐私政策与 Apple 标准条款入口。

操作路径：

1. 在 App Store Connect 确认 Paid Apps Agreement 为 In Effect，订阅商品资料完整并随本次提交。
2. 真机安装 TestFlight build 21，进入「个人 → Holo Plus → 升级 Holo Plus」。
3. 确认商品可加载、价格与周期正确，并至少完成一次 Sandbox 购买和一次恢复购买。
4. 录屏保留点击入口、付费墙打开和商品加载过程。

### 2. Guideline 2.5.1 - Apple Health 真机录屏尚未附加

状态：界面标识已核对，真机证据待完成。

界面当前可见「连接 Apple Health」「授权后只读同步步数、睡眠和活动数据」「健康数据由 Apple Health 提供」。无需把整个模块改名为「Apple 健康」；关键是审核员能在功能入口和授权前页面看见数据来源与用途。

操作路径：

1. 真机打开「首页 → 健康 → 连接 Apple Health」。
2. 录制页面标识、系统授权页、授权后的只读健康数据展示。
3. 把无需登录的录屏链接填入 App Review Information → Notes。
4. 使用 `docs/app-store/review-notes-and-metadata.md` 顶部的重新提交说明回复审核员。

### 3. App Store Connect 元数据未能从本机自动核实

状态：需人工核对。

本机没有 `asc` CLI，无法读取 App Store Connect 中的截图、隐私标签、URL、年龄分级和销售范围。提交前人工核对 Support URL、Privacy Policy URL、版本描述、关键词、截图、App Privacy 与销售区域。

### 4. CloudKit Production schema 待部署

本次数据管理/回收站为多类 Core Data 实体新增软删除字段和 `RecycleBinBatch`。上传前按 `docs/appstore-preflight/CloudKit-schema部署指南.md` 将 Development schema 部署到 Production，并确认 Production 中的新字段和 Record Type 已出现。

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

### 2. 自动化测试

- App 锁定向单元测试：7 项，0 失败。
- 完整单元测试：跳过会长时间不结束的 `HoloLocalAgentRuntimeTests` 桥接用例后，实际执行 767 项，0 失败。
- `HoloTests` 与 `HoloUITests` 测试目标均已编译成功；UI 验收脚本依赖预置数据，本轮未把“编译成功”写成“UI 路径已真机通过”。

### 3. 基础合规能力

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

- [ ] 将本次 Core Data/回收站新增字段部署到 CloudKit Production schema。
- [ ] 用最终提交 commit 生成 signed Archive，并上传 TestFlight build 21。
- [ ] 真机验证「升级 Holo Plus」可打开付费墙、加载 Sandbox 商品、完成购买和恢复购买。
- [ ] 真机录制「首页 → 健康 → 连接 Apple Health → 系统授权 → 只读数据展示」。
- [ ] 将公开录屏链接写入 App Review Information → Notes，并用拒审回复模板回复审核员。
- [ ] 发布最新 `docs/privacy-policy.html` 到线上隐私政策 URL。
- [ ] 在 App Store Connect 填 Support URL 和 Privacy Policy URL。
- [ ] 确认 App Privacy labels 与实际数据处理一致。
- [ ] 选择是否上中国大陆。
- [ ] 准备真机截图。
- [ ] 真机完整走查 Sign in with Apple、AI 授权、HoloAI、语音、HealthKit、iCloud、删除账号与数据。
- [ ] 审核期间保持 `https://api.holoapp.cn` 后端稳定在线。

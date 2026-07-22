# Holo 数据与隐私

## 数据分类

- 高敏感：健康、财务、长期记忆、完整对话和语音。
- 敏感：待办、习惯、想法、位置或日历关联信息。
- 技术元数据：请求 ID、耗时、状态码、模型、token 与发布版本；不得默认夹带正文。

## 最小披露

Agent 工具只返回完成当前问题所需的字段。财务动态目录不暴露账户名或备注，证据样例默认不包含原始 note/remark；金额聚合使用 Decimal，展示层才转换。数据源读取失败必须显式报告 unavailable/error，不能降级为空数组。

## 用户控制

用户可在 App 内控制 AI 数据处理、HealthKit、通知和 iCloud 权限；交易数据支持 CSV/JSON 导出；账号与数据删除入口位于“设置 → 账号与数据”。官网对应入口：`/privacy`、`/terms`、`/support`、`/account-deletion`、`/data-export`。

## 发布一致性

App 内法律文本、`docs/privacy-policy.html`、官网页面、Privacy Manifest、App Store 隐私问卷与后端真实日志策略必须保持一致。任何新增出站字段、第三方服务、数据保留或跨设备同步范围，都必须在提审前重新核对。

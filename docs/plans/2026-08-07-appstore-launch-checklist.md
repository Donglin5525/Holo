# Holo App Store 首版上线清单

> 制定时间：2026-08-07 ｜ 最后更新：2026-08-07（凌晨自动化执行后）
> 分支：`release/1.0.0`
> 原则：**首版目标不是完美，是「能跑、不崩、合规、成本可控」**。体验优化全部进 v1.1。

---

## 当前进度总览

| 阶段 | 内容 | 状态 |
|------|------|------|
| **P0-1** | 冻结首版功能范围 | ✅ 已完成（见下方 commit 记录） |
| **P0-2** | 免费额度 | ✅ 经核实维持现状（无需改动） |
| **P1-1** | MetricKit 崩溃监控 | ✅ 已完成 |
| **P1-2** | 设置页反馈入口 | ✅ 已完成 |
| **B 线** | 表达式引擎 | 🟡 Task 1-5 已完成，Task 6-7 待东林验证 |
| **P2** | App Attest + 会员恢复 | ⬜ 上线后第一周 |

---

## release/1.0.0 分支提交记录

```
bfe0e84  feat(agent): 表达式引擎 Task 3-5 — 采样 + Parser + Prompt
e7f7e08  feat(agent): 表达式引擎核心 — 表达式树 + 求值器 + 校验器 + 引擎集成
02d15b0  feat: 接入 MetricKit 崩溃监控 + 设置页反馈入口
12fc90f  fix: 法律文档联系邮箱更正为官网地址 holoappservice@gmail.com
90b05eb  feat: App Store 首版功能冻结
a910db0  fix(tests): 孤儿清理测试同步方法重命名
```

**主 App 编译状态：✅ 全部通过（Debug + Simulator 验证）**

---

## P0-1 冻结首版（已完成）

**实际执行**：
- 剔除表达式引擎的半成品测试文件（`ExpressionEngineTests.swift`，会编译失败）
- 保留 `HoloQueryRowFormatter.swift`（已完成工具，B 线复用）和 `VerifyExpressionEngine.swift`（独立脚本，不害编译）
- 删除 `docs/_tmp_screen.png` 临时截图
- AI 体验大改（15 项）+ 想法标签整理 + 各模块优化 作为一个提交冻结
- 修复了 `ChatMessageRepositoryOrphanCleanupTests` 方法名过时问题（`cleanupOrphanedStreamingMessages` → `OffMain`）

**已知遗留**：HoloTests target 因 100+ 个 Standalone 文件含 `@main` 无法批量编译——这是长期存在的工程配置问题，不阻塞首版（主 App 编译正常）。留作上线后独立任务。

## P0-2 额度（经核实维持现状）

**核实结论**：最初判断有误。实际上有两套独立配置：
- `quotaPolicy.js`：**免费用户档位配额**（chat=3/天、ASR=20/天）—— 这是文案显示的数字，本来就一致
- `config.js`：**防刷限流上限**（chat=50/天、ASR=20/天）—— 防恶意刷接口

文案与档位配额从来就对得上，无需改动。真正的成本风险在 App Attest（P2）未接入导致的设备伪造，不在配额数字。

## P1 崩溃监控 + 反馈入口（已完成）

**MetricKit 崩溃监控**：
- 新增 `HoloMetricManager`（订阅崩溃/卡顿/CPU异常/磁盘写入异常）
- 新增 `HoloDiagnosticLogger`（按天写文件，保留 7 天，自动清理）
- HoloApp 启动时启动订阅
- **局限**：模拟器不交付数据，真机验证留 TestFlight；非实时（按天批量）

**反馈入口**：
- 新增 `HoloFeedbackMailer`（邮件封装，预填设备信息 + 可附诊断日志）
- 新增 `HoloDiagnosticsView`（设置页「诊断与反馈」入口）
- 邮箱更正为官网地址 `holoappservice@gmail.com`（原 `support@holoapp.cn` 是错的）

---

## B 线：表达式引擎（Task 1-5 完成，6-7 待验证）

### 已完成（编译通过）

| Task | 内容 |
|------|------|
| 1 | 表达式树 `HoloExpressionNode`（6 种节点 + 手写 Codable）+ 求值器 + 校验器 |
| 2 | 引擎集成：`derive()` 加 expression 分支 + `validate()` 加校验 + 语义映射 |
| 3 | 查询结果附带 10 条样本（`HoloDynamicQuerySampler`）+ `HoloDataToolResult.sampleRows` |
| 4 | Prompt 模板 v4→v5，加 expression 说明 + 算烟场景示例 |
| 5 | Response Parser（自动合成 Codable，无需额外代码） |

### 待东林验证（有风险，不擅自做）

| Task | 内容 | 为什么留给你 |
|------|------|------------|
| 6 | Runtime 采样注入 + 告知卡片 UI | 改动 AI 对话主循环（runLoop），需清醒验证 |
| 7 | 端到端真机测试 | 依赖真实 AI 是否正确生成表达式，无法模拟器验证 |

**Task 6 要做的事**（醒来后做）：
- 在 `HoloLocalAgentRuntime.runLoop` 里，执行 toolRequest 后检查 `result.sampleRows`
- 若有样本：序列化为文本注入下一轮 context + 产出告知卡片消息
- 新建 Chat 卡片视图展示采样列表

**Task 7 要做的事**：
- 真机问「算算我日均抽几根烟」（需先有烟相关记账数据）
- 验证 AI 是否正确生成 expression plan + 告知卡片 + 计算结果

### 需后端发版

- `HoloBackend/src/prompts/promptRegistry.js` 要同步 flexibleQueryPlanner v5 的 expression 说明

---

## P2 上线后第一周（未开始）

### P2-1 App Attest（防伪造）

**调查结论**：后端 App Attest 是**空壳**——challenge 接口能用但 nonce 未落库可重放；assert 接口返回 401「not implemented yet」；无 CBOR 解析库；`getDeviceId` 只看 header 不校验，带任意字符串即可绕过。

**步骤**：
1. 后端：加 CBOR 依赖，实现 assert 验证链（证书链 + 签名），challenge 落库 + 绑定设备
2. iOS：封装 `DCAppAttestService`，challenge → generateKey → attestKey → assert
3. 软上线（enforceAppAttest=false 观察）→ 确认无异常 → 切 true

### P2-2 验证换设备恢复会员

人工测试：A 设备购买 → B 设备同 Apple ID 登录 → 恢复购买 → 验证会员状态正确。

---

## ⚠️ 需要东林拍板的风险点

1. **表达式引擎 Task 6-7 未完成**：当前表达式引擎核心已就绪但无法端到端验证。首版是否包含它，取决于 Task 6-7 你醒来后是否来得及做完和验证。
2. **HoloTests target 批量测试不可用**：100+ Standalone 文件含 @main 冲突。不阻塞首版，但意味着发版前没法用测试兜底。
3. **后端 promptRegistry.js 未同步**：表达式引擎的 prompt 改了客户端，但后端托管版没同步。如果生产以后端托管为准，Task 4 不发版不生效。
4. **无线上崩溃监控的真实数据验证**：MetricKit 模拟器不交付，真机效果未知。
5. **App Store 审核相关事项未核查**（ASC 后台隐私问卷、AI 备案等，见最初讨论）。

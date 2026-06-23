# Holo 离线 AI 图标工坊设计

日期：2026-06-24

## 背景

Holo 当前财务、待办、习惯模块的内置图标主要依赖 SF Symbol、少量自绘 fallback 和既有 Asset Catalog 资源。现状的问题不是单个图标不好看，而是三类体验同时存在：

- 业务语义不够准确，例如用泛化的太阳、月亮、胡萝卜表达具体生活分类。
- 不同入口的图标来源可能不一致，财务分类、聊天确认卡片、图标选择器、待办入口和习惯预设容易出现割裂。
- Holo 缺少一套稳定的自有图标生产和审核机制，后续维护容易反复回到“凭感觉换图标”。

本方案建立一个仓库内的离线图标工坊，用于批量生成、校验、审核并入库 Holo 自绘业务语义图标。绘制能力通过外部模型 API 接入，生成 token 不走 Codex。

## 目标

第一批覆盖财务分类、待办业务语义图标、习惯预设图标，完成内置业务语义图标的全量替换。

用户可见效果是：Holo 的图标从“拼接系统符号”变成一套自己的生活记录语言，更统一、更柔和、更有品牌气质，同时仍然一眼能懂、小尺寸清楚、可随模块主题色模板着色。

## 非目标

- 不做线上动态图标生成服务。
- 不接入 HoloBackend，不引入后端部署链路。
- 不让 App 运行时请求模型生成图标。
- 不替换返回、关闭、搜索、删除、设置、展开收起等系统操作图标。
- 不把完整源码、用户数据、密钥、记忆内容发送给外部模型。

## 已确认决策

- 工具形态：本地/内部离线工坊。
- 覆盖范围：财务、待办、习惯三大模块的业务语义图标。
- 视觉语言：轻填充轮廓。
- 语义策略：生活场景化。
- 生成方式：外部模型直接返回 SVG。
- 审查方式：AI 预审 + 用户终审。
- 入库策略：终审通过后才写入 iOS 资产和映射表。

## 图标设计语言

每个图标只允许一个核心主物件，再加最多一到两个轻量场景线索。主物件保证一眼识别，场景线索提供 Holo 的生活温度。

统一约束：

- `viewBox="0 0 24 24"`。
- 轻填充轮廓，填充透明度建议 8% 到 12%。
- 单色模板图标，支持 SwiftUI 主题色着色。
- 圆角线帽、圆角连接。
- 禁止渐变、阴影、3D、表情包化、复杂纹理。
- 16pt、20pt、28pt 三档预览都要清晰。

示例原则：

- 早餐不使用单独的太阳隐喻，优先使用碗或盘，加轻微热气和晨间线索。
- 待办不使用冷冰冰的抽象 checklist，优先使用清单载体和完成动作。
- 财务不堆叠钱币，优先表达交易动作、收入流向、支出场景或资产状态。

## 总体架构

工坊由五层组成：

1. 图标盘点层：从现有代码中抽取业务图标清单。
2. 语义卡层：为每个图标定义主物件、场景线索、禁止隐喻和输出规范。
3. Provider 层：调用用户配置的外部模型 API，生成 SVG 候选。
4. 校验与预审层：检查 SVG 可用性，给出 AI 预审分数和问题说明。
5. 入库导出层：将终审通过的图标写入资产目录、映射表、预览和测试。

工坊不参与 App 运行时逻辑。App 只消费最终入库后的静态资产和映射。

## 建议文件结构

```text
tools/icon-workshop/
  manifest/
    holo-icons.manifest.json
  providers/
    provider.interface.json
    example-provider.config.json
  prompts/
    system.md
    icon-card-template.md
  src/
    scan-icons.ts
    build-prompts.ts
    generate-candidates.ts
    validate-svg.ts
    review-candidates.ts
    export-assets.ts
  output/
    candidates/
    previews/
    reports/
```

`tools/icon-workshop/output/` 保存生成结果、预览和报告，不直接代表已入库资产。只有终审通过并执行 export 后，图标才会进入 iOS 资产目录和代码映射。

## 命令入口

```bash
npm run icons:scan
npm run icons:generate
npm run icons:validate
npm run icons:review
npm run icons:export
```

命令职责：

- `icons:scan`：读取财务分类、待办业务语义图标、习惯预设，生成 manifest。
- `icons:generate`：根据 manifest 和语义卡调用外部模型 API，生成 3 到 5 个 SVG 候选。
- `icons:validate`：校验 SVG 规格、复杂度、模板着色和小尺寸预览。
- `icons:review`：生成 HTML/JSON 审查报告，包含 AI 预审分数和候选对比。
- `icons:export`：只导出用户终审通过的图标，并同步资产、映射和测试。

## Manifest 模型

manifest 是整个工坊的单一输入清单。每条记录包含：

```json
{
  "iconId": "finance.expense.food.breakfast",
  "module": "finance",
  "displayName": "早餐",
  "currentIcon": "sunrise.fill",
  "usage": ["finance-category", "chat-card", "icon-picker"],
  "semanticCard": {
    "primaryObject": "small bowl or plate",
    "sceneCue": "gentle steam, subtle morning cue",
    "avoid": ["sun-only metaphor", "emoji style", "3D", "gradient", "shadow"]
  }
}
```

`iconId` 必须稳定，用于候选缓存、重试、审查报告和最终导出。

## Provider 合约

Provider 是外部模型适配层。更换模型时，只改 provider 配置或适配器，不改工坊主流程。

请求示例：

```json
{
  "iconId": "finance.expense.food.breakfast",
  "module": "finance",
  "displayName": "早餐",
  "style": {
    "visualLanguage": "light-filled-outline",
    "semanticMode": "life-scene",
    "viewBox": "0 0 24 24",
    "templateColor": true
  },
  "brief": {
    "primaryObject": "small bowl or plate",
    "sceneCue": "gentle steam, subtle morning cue",
    "avoid": ["sun-only metaphor", "emoji style", "3D", "gradient", "shadow"]
  },
  "count": 5
}
```

响应示例：

```json
{
  "iconId": "finance.expense.food.breakfast",
  "candidates": [
    {
      "candidateId": "v1",
      "svg": "<svg ...>...</svg>",
      "rationale": "Uses bowl and steam to express breakfast.",
      "selfScore": {
        "recognition": 86,
        "semanticAccuracy": 90,
        "styleConsistency": 82
      },
      "warnings": []
    }
  ]
}
```

不合格响应：

- Markdown 包裹的解释文本。
- HTML 页面。
- 位图链接。
- 多色插画。
- 无法解析为 SVG 的字符串。
- 缺少 `iconId` 或 `candidates`。

这些情况直接判为 provider 输出失败，不进入人审。

## 安全与配置

API key 只允许来自本地环境变量或 ignored 本地配置文件。示例配置可以提交，但真实密钥不能提交。

请求外部模型时只发送语义卡和 SVG 规范，不发送完整源码、不发送用户数据、不发送记忆内容、不发送任何密钥。

建议支持：

- `ICON_WORKSHOP_PROVIDER_ENDPOINT`
- `ICON_WORKSHOP_PROVIDER_API_KEY`
- `ICON_WORKSHOP_PROVIDER_MODEL`
- `ICON_WORKSHOP_PROVIDER_TIMEOUT_MS`
- `ICON_WORKSHOP_PROVIDER_RATE_LIMIT`

## 自动校验

`icons:validate` 至少检查：

- SVG 是否可解析。
- `viewBox` 是否为 `0 0 24 24`。
- 是否只使用允许的 `path`、`circle`、`rect`、`line`、`polyline`、`polygon` 等基础元素。
- 是否包含渐变、滤镜、阴影、外链、脚本或样式变量。
- `fill` 和 `stroke` 是否满足模板着色规则。
- path 数量是否过多。
- 是否能生成 16pt、20pt、28pt 预览。
- 小尺寸预览是否出现明显糊团或不可区分。

校验失败要输出可读错误，作为下一轮重画约束。

## 审查报告

每轮生成后输出 HTML/JSON 报告，面向终审使用。

报告内容：

- 图标名、模块、当前旧图标。
- 语义卡摘要。
- 3 到 5 个 SVG 候选。
- 16pt、20pt、28pt 预览。
- 自动校验结果。
- AI 预审分数。
- 用户终审动作：通过、重画、暂缓、手动替换。
- 用户反馈：用于下一轮重画。

评分权重：

- 一眼识别：30%。
- 语义准确：25%。
- 风格一致：20%。
- 小尺寸清楚：15%。
- 耐看温度：10%。

低于 80 分不入库。一眼识别或语义准确任一低于 70 分，直接重画。

## 反馈闭环

用户点击“重画”时，工坊将终审反馈写入下一轮请求。

示例：

```json
{
  "revisionInstruction": "Keep the bowl, simplify steam to one stroke, avoid sun rays."
}
```

重画只针对单个 `iconId`，不重新生成整批图标。

## 入库导出

`icons:export` 只处理终审通过的候选。导出动作包括：

- 写入 iOS Asset Catalog 或约定的 SVG 资产目录。
- 更新财务分类映射、聊天卡片映射、图标选择器目录。
- 更新待办业务语义图标映射。
- 更新习惯预设图标映射。
- 生成入库快照和测试期望。

入库后要防止“主列表已更新、聊天卡片仍是旧图标”这类割裂。

## 失败重试

每个图标独立生成、校验、审查和重试。单个图标失败不阻塞整批。

失败原因需要结构化记录：

- provider 调用失败。
- provider 响应格式错误。
- SVG 解析失败。
- SVG 规格不合格。
- AI 预审不合格。
- 用户终审打回。

后续重试必须复用失败原因和用户反馈，避免重复生成同类错误。

## 测试与验证

实现时建议覆盖：

- manifest 生成测试：确认财务、待办、习惯图标都被收集。
- provider 响应解析测试：合格与不合格响应都能正确处理。
- SVG 校验测试：拦截渐变、脚本、外链、错误 viewBox、多色图标。
- review 报告生成测试：候选、分数、预览和终审状态完整。
- export dry-run 测试：确认会修改哪些资产和映射。
- iOS 编译验证：确保导出的资产和映射不会破坏 App 构建。

## 风险与防线

| 风险 | 防线 |
| --- | --- |
| AI 输出漂亮但不可用的 SVG | 自动校验 viewBox、颜色、path 数、模板着色和小尺寸预览 |
| 单张好看但整组割裂 | 按模块和同组图标成组审查 |
| App 某些入口仍显示旧图标 | export 同步资产、映射表、图标选择器、聊天卡片和测试 |
| 模型成本失控 | 单图标重试、候选缓存、只重画失败项 |
| 外部模型泄露敏感上下文 | 请求只包含语义卡和图标规范 |

## 分阶段落地

第一阶段：工坊骨架。

- 建立 manifest、provider 合约、校验器、报告生成。
- 支持 dry-run，不写入 App 资产。

第二阶段：接入外部模型。

- 支持配置 endpoint、api key、model。
- 跑通单个图标生成、校验、预审、终审反馈闭环。

第三阶段：批量生成和人审。

- 覆盖财务、待办、习惯三大模块。
- 生成按模块分组的 HTML 审查报告。

第四阶段：入库导出。

- 写入资产和映射。
- 补齐测试和构建验证。

第五阶段：质量收尾。

- 成组复查。
- 清理旧图标映射。
- 更新文档和 changelog。

## 验收标准

- 能从当前代码生成完整业务语义图标 manifest。
- 能通过外部 provider 获取 SVG 候选，且 token 消耗不走 Codex。
- 能自动拦截不合规 SVG。
- 能生成可人工终审的报告。
- 能按单个图标重试并携带反馈。
- 终审通过后能稳定导出资产和映射。
- 财务、待办、习惯主要入口不会出现新旧图标混用。

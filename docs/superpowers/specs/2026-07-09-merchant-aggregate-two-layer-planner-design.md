# Holo 商户聚合查询两层 Planner 设计

## 目标

让“最近一个月吃了多少顿麦当劳，花了多少钱，平均一顿多少钱”这类确定性问题稳定返回次数、总额和均价，不再因模型推理预算不足、非法 JSON 或分析模板而失败。

成功标准：

1. 明确的商户聚合问题不依赖 LLM 规划，客户端直接生成受控查询计划。
2. 其他灵活查询使用独立的后端 Planner 路由，不再共享普通聊天的 1024-token 预算。
3. 计算仍由 `FlexibleQueryExecutor` 完成，模型不能直接生成金额、次数或均价。
4. 无法无歧义确定商户、时间范围或指标时，不猜测，回退到专用 Planner。

## 架构

### 第一层：客户端确定性 Fast-path

在 `FlexibleQueryPlanner` 调用 LLM 前增加一个独立、可单测的 `MerchantAggregatePlanResolver`。

它只在以下条件全部满足时命中：

- 财务支出查询；
- 有明确商户关键词，优先取 intent 的 `categoryHint`，其次从受控 queryGoal 中提取；
- 用户同时要求次数、总额和平均金额；
- 平均单位能从“每笔 / 每次 / 每顿”明确判断；
- 时间范围属于本地可确定解析的表达，本次至少支持“最近一个月 / 近30天”。

命中后生成：

- `operation = sumAmount`
- `calculation = averageAmount`
- `averageUnit = meal / occurrence / transaction`
- `summary.totalMatched` 作为次数
- 商户写入 `filters.keywords`
- “最近一个月 / 近30天”使用含当天在内的 30 天范围

“吨麦当劳”只有在同一句出现“吃了多少吨”和“平均一顿”时才按“顿”纠正；不会把一般重量查询擅自改成餐次。

### 第二层：后端专用 Planner 路由

新增 `flexible_query_planner` purpose：

- provider/model 默认继承 intent，再回退 chat；
- temperature = 0；
- maxTokens = 4096；
- 使用独立限流口径或沿用普通聊天总额度，不接受客户端指定模型和 token；
- iOS `HoloBackendAIProvider` 通过新的 purpose 发起非流式 JSON 请求。

为保持其他 Provider 兼容，`AIProvider` 增加语义化的 Planner 调用方法：

- 默认实现回退到原有 `chat(messages:userContext:)`；
- `HoloBackendAIProvider` 覆盖实现，调用后端 `flexible_query_planner` purpose；
- `FlexibleQueryPlanner` 不做具体 Provider 类型判断。

## 数据流

1. Intent v22 将确定性商户聚合问题路由到 `flexible_data_query`。
2. `FlexibleQueryPlanner` 先调用本地 resolver。
3. 命中：直接得到 `FlexibleQueryPlan`。
4. 未命中：调用后端专用 Planner。
5. `FlexibleQueryExecutor` 查询账单并计算 `totalMatched`、`totalAmount`、`averageAmount`。
6. AnswerBuilder 和查询卡片直接展示三个确定结果。

## 错误处理

- Fast-path 只处理完整确定的输入；缺商户、缺时间或均价单位不明时返回 nil。
- 专用 Planner 返回空正文、非法 JSON 或不合法计划时，沿用现有错误处理，不伪造结果。
- 不为修复 Planner 而提升所有普通聊天请求的 token 上限，避免无关成本扩大。
- 服务器部署继续保留现有 ECS stash，不恢复或覆盖历史改动。

## 测试

### iOS

- 原始“吨 / 顿”麦当劳问题命中 fast-path。
- 计划包含麦当劳、30 天范围、`sumAmount`、`averageAmount`、`meal`。
- 缺商户或只问趋势时不命中。
- `FlexibleQueryPlanner` 命中 fast-path 时不调用 AIProvider。
- 未命中时调用语义化 Planner 方法。
- 现有回答和卡片测试继续验证 5 顿、239 元、47.80 元。

### 后端

- config 暴露 `flexible_query_planner` 路由，默认 maxTokens 不低于 4096。
- API 接受该 purpose，并将请求路由到配置的 Provider。
- release status 显示该路由。
- 全量后端测试通过。

### 发布验收

- iOS 主工程和 HoloTests target 构建通过。
- 后端全量测试通过。
- ECS Docker 重建、容器健康检查、公网健康检查通过。
- 生产专用 Planner 对原始问题输出 `sumAmount + averageAmount + meal + 麦当劳`。

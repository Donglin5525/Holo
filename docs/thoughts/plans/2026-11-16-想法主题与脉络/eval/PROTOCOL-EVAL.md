# W4 协议层评测报告 · 「想法自动整理增强」

- 运行日期:2026-11-16
- 跑批脚本:[tools/run-protocol-eval.mjs](tools/run-protocol-eval.mjs)(零 npm 依赖,ESM)
- 机器可读结果:[protocol-eval-report.json](protocol-eval-report.json)(每次运行幂等覆盖)
- 被测对象:**后端真实校验器源文件**,非复刻、非 mock——
  - `HoloBackend/src/thoughts/followupSchema.js`:`validateFollowupRequest` + `validateFollowupModelOutput`(§6 C2 verify-followup,含 `quoteAlignment.js` 逐字回源)
  - `HoloBackend/src/thoughts/semanticRelateSchema.js`:`validateRelateRequest`(schema 4 definition 校验,§4 A1)

## 1. 跑法

```bash
node "/Users/tangyuxuan/Desktop/Claude/HOLO/docs/thoughts/plans/2026-11-16-想法主题与脉络/eval/tools/run-protocol-eval.mjs"
```

- 脚本以自身位置定位语料与协议真源,任意目录可跑;不联网、不调模型、不写库。
- 先做语料分母复核(与 README 冻结表逐一对照,不一致即视为语料被污染并终止,退出码 1)。
- 三段评测,全部喂进真实校验器;每例记录逐项 PASS/FAIL 到 `protocol-eval-report.json`,人读摘要打到 stdout。
- 幂等:重复运行覆盖同一份报告文件。

## 2. 分母表(实际运行复核值 = README 冻结表)

| 分母 | 数值 | 用在哪段 |
|---|---|---|
| 语料笔记 | 50 条 | 分母复核 |
| 预标注关系对 | **61** 对(成立 45 + 负向 16) | A 正向集 |
| 预标脉络 | **3** 条(T1/T2/T3,成员各 5) | A 正向集 |
| 结构反证组 | **7** 组(共 10 例) | B 反证集 |
| 规则样本 | **14** 条(rule-samples.json) | C schema 4 |
| schema 4 超限派生例 | **14** 例(每条规则派生一个 241 UTF-16 例) | C schema 4 |

A 段合计分母 = 61 + 3 = **64**。全部检查合计 = 64 + 10 + 14 + 14 = **102**。

## 3. 结果表(2026-11-16 实跑)

| 段 | 分母 | 结果 | 说明 |
|---|---|---|---|
| A 正向集 · 关系对 | 61 | **61 通过 / 0 失败** | 45 对成立关系带双侧真实引文逐字回源;16 对 none/insufficient 按 labels-key §3 证据与 reason 全 null;canonical 回显(引文原样、区间长度与引文一致、负向全 null)逐例断言通过 |
| A 正向集 · 脉络 | 3 | **3 通过 / 0 失败** | 3 条脉络 5 成员、锚点首位、其余成员逐条有成立关系,thread 回显与预标一致 |
| B 结构反证集 | 10 例 / 7 组 | **10 例全部按预期拒绝** | 逐例拒绝原因见下表 |
| C schema 4 · 规则 ≤240 | 14 | **14 通过 / 0 失败** | rule-samples 全部 categoryRule(实测最长 69 UTF-16)通过 `validateRelateRequest` |
| C schema 4 · 派生 241 超限 | 14 | **14 全部拒绝** | 统一报 `INVALID_REQUEST` |
| **合计** | **102** | **102 / 102** | 退出码 0 |

### B 段逐例(全部派生自语料真实文本)

| 例 | 组 | 派生 | 预期 | 实际拒绝原因 |
|---|---|---|---|---|
| X01 | G1 伪造引文 | N44→N04 revises 锚侧引文「低风险自动,高影响先确认」改一字为「批」 | 拒 | `anchor_evidence_invalid` |
| X02 | G1 伪造引文 | N44→N24 continues 对方侧引文「出错的时候是真难纠正」改一字为「改」 | 拒 | `other_evidence_invalid` |
| X03 | G2 range 越界/错位 | N50→N44 锚侧 rangeUTF16 端点 = 窗口长+5 | 拒 | `anchor_evidence_invalid` |
| X04 | G2 range 越界/错位 | N50→N44 对方侧 rangeUTF16 起点>终点 [10,5] | 拒 | `other_evidence_invalid` |
| X05 | G3 none 带证据 | N44→N16 none(H01 转述)照抄语料「表面相似」审计引文 + reason | 拒 | `negative_decision_fields_not_null` |
| X06 | G3 none 带证据 | N27→N18 none(H09 计划)仅 reason 非 null | 拒 | `negative_decision_fields_not_null` |
| X07 | G4 thread 缺锚点 | T1 memberRefs 去掉锚点 N44 | 拒 | `thread_missing_anchor` |
| X08 | G5 thread 成员<3 | T1 memberRefs 仅 2 个 | 拒 | `thread_member_count` |
| X09 | G6 标题超 32 | T1 标题重复 4 次 = 36 UTF-16 > 32 | 拒 | `thread_title_shape` |
| X10 | G7 windowRef 虚构 | N34→N07 锚点证据 windowRef 指向不存在的「W9」 | 拒 | `anchor_evidence_invalid` |

### 口径说明(两点,避免误读)

1. **窗口内「错位但未越界」的 rangeUTF16 不属于协议拒绝范围**:校验器对模型给的区间只做结构检查(非负整数、半开区间形状、端点不越窗口),数值本身由服务端从 canonical quote 重算(`followupSchema.js` canonicalEvidence 注释,与 semantic-relate v2+ 同口径)。因此 G2 以「越界」与「倒置」两例考察拒绝行为,窗口内的良性错位由服务端静默纠正,这是设计而非漏网。
2. **none/insufficient 的语料审计引文**(labels-key §3 声明的协议偏离)在 A 段组装时全部置 null;X05 专门验证「naive 模型照抄审计引文」会被校验器整批拒绝,即协议层确实兜住了这条偏离声明。

## 4. 结论:协议层放行线

放行线:正向集 100% 通过、结构反证集 100% 拒绝、schema 4 definition 两向全符合。

**结果:达标(PASS)。** 正向 64/64(100%),反证 10/10(100% 拒),schema 4 14/14 通过 + 14/14 拒绝。协议层(结构、证据、逐字回源)的接受与拒绝行为与 §6 C2 契约一致,可作为后续模型评测的固定协议闸。

## 5. 与 §9 七层证据的对应

§9 要求交付报告分七层:静态检查 / 单测契约 / 隔离模拟器 / 真机 / 同混版本双设备 / 授权样本产品效果 / 生产版本与首跑。本批覆盖其中前两层:

| 层 | 本批贡献 | 状态 |
|---|---|---|
| 静态检查 | 语料分母机械复核(50/61/45/16/3 与冻结表一致)、引文逐字命中、脉络锚点全连接(复核即失败闸) | ✅ 本批完成 |
| 单测 / 契约 | 61+3 正向形状与 canonical 回显、10 例协议违例拒绝、schema 4 definition ≤240/241 边界——全部走后端真实校验器函数,属契约层行为验证 | ✅ 本批完成 |
| 隔离模拟器 / 真机 / 双设备 / 授权样本 / 生产 | 端到端出卡、找回价值、盲评、费用与运维指标 | ⬜ 不在本批范围,待后续 |

## 6. 明确声明:语义层未跑

本批只验证**协议层**(结构合法、证据可逐字回源、违例拒绝)。**语义层——关系判断质量(continues/adds_example/revises 是否判得对、45 对成立关系的展示准确率 ≥85%、16 对负向不误出、硬负例 15 组错出 ≤1/12、找回价值、规则兑现)——需要真实模型产生判断后才能评测,本批零模型调用,一律未跑。** 硬负例组(hard-negatives.json)的语义预期已由语料 groundTruth 承载(verify.js E2 已校验标注一致),待模型评测段直接使用。

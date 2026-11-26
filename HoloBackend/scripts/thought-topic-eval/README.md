# 想法主题归类评测（「尺子」）

方案：`docs/thoughts/plans/2026-11-24-想法主题归类准确性闭环/实施方案.md` §4 P0。

目的：量出 Holo 把想法自动整理进主题，到底整理得好不好。以后每次改判定逻辑、提示词或落库规则，
都拿它量一遍，不达标不放量（方案 §8）。

## 评测口径（2026-11-25 东林定）

**每条去掉 `#标签` 的笔记，单独让线上模型归纳 1–3 个主题**；不看任何主题清单，也不用用户打过的标签。
然后抽正好 200 条给东林逐个点「对 / 不对」，可补「漏了的主题」。

```bash
# 在 HoloBackend 目录下。直连线上同款模型（qwen3.7-flash），不需要起本机后端
node scripts/thought-topic-eval/per-note-topics.mjs run     # 逐条归纳，可中断续跑
node scripts/thought-topic-eval/per-note-topics.mjs page   # 抽正好 200 条，生成 eval/private/grade-per-note-topics.html
```

下面各节是另外两种跑法，不是当前口径：`independent-run.mjs` 模拟 Holo 自己长主题的全流程；
`run.mjs` 要求数据集自带主题与答案。

## 怎么跑

```bash
# 0. 自查（零网络、零费用；改过 lib/ 下任何文件后必跑）
node scripts/thought-topic-eval/selftest.mjs
python3 -I scripts/thought-topic-eval/convert_flomo.py --selftest

# 1. 本机起线上同款后端（另开终端常驻；独立端口 8797 + 评测专用数据库，不碰线上）
bash scripts/thought-topic-eval/serve.sh

# 2. 原文去掉标签，转成不带任何主题的数据集
python3 -I scripts/thought-topic-eval/convert_flomo.py \
  --raw-dir eval/private/raw --out eval/private/dataset/flomo-raw.json --name flomo-raw --topics none

# 3. Holo 独立整理一版（纯自动：不带预设分类；--presets default 则带引导页预设的前四个）
node scripts/thought-topic-eval/independent-run.mjs \
  --dataset eval/private/dataset/flomo-raw.json --presets none --lanes 12 --tag auto

# 4. 从结果里抽正好 200 条，生成盲标页
node scripts/thought-topic-eval/make-label-sheet.mjs \
  --results eval/private/results/independent-auto.json --sample 200
# → eval/private/independent-auto.html，双击打开；标完点「导出 gold.json」

# 5. 按东林的标注评分
node scripts/thought-topic-eval/rescore.mjs \
  --results eval/private/results/independent-auto.json --gold <gold.json>
node scripts/thought-topic-eval/summarize.mjs --results <重新评分后的结果.json>
```

产出：

- 含正文的结果 JSON、标注页 → `eval/private/`（已 gitignore；写之前脚本会校验确实被忽略）
- 只含聚合数字的报告 → `eval/report-*.md`（可入库；主题只以 id 出现）

本机 `.env` 的 `QWEN_API_KEY` 若为空，`serve.sh` 会回退用 `DASHSCOPE_API_KEY`（同一 DashScope 通道，
模型与线上一致，计费走这把钥匙的账号）。想与线上用同一把钥匙：在 `HoloBackend/.env` 填 `QWEN_API_KEY`。

### 只为评测放宽的配置（都在 serve.sh）

- **费用护栏**：价目表取线上的值；上限放宽到单设备 ¥5/天、全局 ¥30/天。默认的「单设备 ¥0.30/天、
  全局 ¥3/天」是给真实用户流量定的，一场几百条的评测会把它撞穿，之后每个请求都在入口被挡。
  脚本遇到护栏拦截会立刻整场停下。
- **重试间隔**：答卷不合规时 1.5 秒就重试（线上是 60 秒起、第 3 次起 15 分钟）。

### 线上现状的两个硬特点（2026-11-25 对照实验实测）

- **答卷不合规是常态**：面对「9 个候选 + 各 3 条真实样例」的归属判定，每 4 次调用约有 1 次答卷不合规
  （漏答候选，或引文与原文对不上），与并发无关。给一簇笔记起主题名时更严重，约五分之四的调用因
  「引用不是逐字」被拒。
- **判断本身在摇摆**：同一条想法同样的问法，问两遍只有五六成相同，所以稳定性必须多轮量。
  复核用 `concurrency-probe.mjs --dataset <数据集.json> --lanes 1,16`。

## Holo 独立整理是怎么模拟的

想法按时间先后一批批「写进 Holo」，每一步都走线上同一条判定路径（`lib/evaluate.mjs`）：

1. **每条想法判一次归属**：候选 = 归档类别（全量直达）+ 已有的内容主题（按质心与近邻召回）；
   线上同款模型判定，按现状落库规则归入（最多 3 个）。
2. **类别理解**：归档类别攒够 5 个成员后，由线上同款模型起草一份「这个主题收什么」，之后的判定带上它。
3. **自动发现主题**：每处理一批就跑到没有新主题为止——没归属的想法里找相似簇（成员 ≥3），
   按内聚度从高到低每轮给最多 2 簇起名；模型认为「不足以成主题」的跳过；起名成功就建主题，
   并把模型点名的成员直接归进去。
4. **全部写完后按最终主题目录重判一遍**（线上每建一个主题都会全库重判）。

与线上的差别（为省调用做的近似，不改变单次判定的口径）：近邻用精确余弦代替近似检索；
建主题后只重判「新主题进了候选」的未归属想法，而不是全库；起名失败最多再试两轮；
类别理解每类只起草一次；按整批导入模拟，不模拟线上单设备日额度带来的数天延迟。

## 数据从哪来

### flomo 导出包

```bash
# 压缩包里只取笔记 HTML，各自解到独立目录（三包里的文件夹同名，直接解会互相覆盖）
python3 -I scripts/thought-topic-eval/convert_flomo.py --selftest
python3 -I scripts/thought-topic-eval/convert_flomo.py \
  --raw-dir eval/private/raw --out eval/private/dataset/flomo-raw.json --name flomo-raw --topics none
```

- **`--topics none`（独立整理用）**：标签全部丢掉，只要原文。
- **`--topics category` / `--topics tag`**：把标签转成主题和答案，只适合「Holo 能不能复现用户手工标签」
  这类对照，不是本评测的口径。
- 正文里的 `#标签` 一律删掉；标签识别不要求前面有空格（中文笔记里标签常紧贴正文）。

### 人工标注

```bash
node scripts/thought-topic-eval/make-label-sheet.mjs --results eval/private/results/<独立整理结果>.json --sample 200
# → eval/private/label-<结果名>.html，双击打开；标完点「导出 gold.json」
```

盲标页：每条显示正文 + Holo 自己整理出的全部主题（最多勾 3 个）+「都不该放」+「拿不准」+
可选的「该单独成一个主题：____」。按时间三等分各抽同样多，总数正好 200。改动随时存在浏览器本地，
用同一个浏览器重新打开会接着上次的进度。改完答案不用重新问模型，直接重新评分。

## 数据集格式（中间格式）

评测脚本只认这个格式。字段说明见 `fixtures/smoke-synthetic.json`（全合成，可直接拿来当冒烟样本）。

```jsonc
{
  "formatVersion": 1,
  "name": "数据集名",
  "topics": [                                   // 独立整理时为空数组
    {
      "id": "UUID",
      "title": "主题名",
      "status": "classification",            // classification=用户启用的归档类别；active/candidate=内容主题
      "categoryDefinition": "用户写的规则，没有就省略",
      "briefDefinition": "AI 起草的类别理解，没有就省略",   // 可选
      "summary": "AI 主题摘要，没有就省略"                  // 可选
    }
  ],
  "thoughts": [
    {
      "id": "UUID",
      "text": "想法正文",
      "createdAt": "2026-10-01T08:00:00+08:00",
      "updatedAt": "2026-10-01T08:00:00+08:00",           // 省略则取 createdAt
      "links": [                                          // 这条想法现在属于哪些主题；可为空数组
        { "topicId": "UUID", "source": "user", "state": "active" }
        // source: user=用户放入/确认  ai=Holo 自动归入  legacy=历史归集
        // state : active / rejected（用户移出的墓碑）/ superseded
        // ai 关系可带 basisTextHash：生成时的正文哈希；省略视为与当前正文一致
      ],
      "split": "dev",                                     // dev / holdout；省略=只当语料，不参与评测
      "gold": { "topicIds": ["UUID"], "unsure": false }   // 正确答案；省略=只当语料
    }
  ]
}
```

- **语料尽量全、标注可以抽样。** 没有金标的想法照样参与召回（当近邻、当主题成员、当代表例）。
- **`links` 是「现状」**，决定代表例、主题质心、哪些旧归属会被撤销。标签即归属的数据集若要量
  「能否复现标签」，必须配 `--leave-one-out`（`run.mjs`）。

## 脚本在做什么

把 iOS 客户端的整理流程 1:1 搬到 Node，再接本机后端的真实模型：

| 步骤 | 对应客户端代码 | 本目录 |
|---|---|---|
| 脱敏、切块、内容哈希 | `ThoughtSemanticText` / `ThoughtIndexV2Policy` | `lib/text.mjs` |
| 关系投影（有效成员、代表例取样序、落库守卫） | `ThoughtTopicLinkProjection` | `lib/projection.mjs` |
| 向量化（脱敏 → 2000 分段加权 → 归一化 → 半精度） | `ThoughtSemanticEmbeddingExecutor` | `lib/vectors.mjs` |
| 候选召回（类别全量直达 + 脉络质心/近邻投票） | `ThoughtTopicCandidateEngine` | `lib/recall.mjs` |
| 组装请求、客户端二次复核、现状落库规则 | `ThoughtTopicVerifier.evaluateLegacy` | `lib/legacy.mjs` |
| 单条想法的一轮评测 | `ThoughtSemanticRelateExecutor` | `lib/evaluate.mjs` |
| 自动发现主题的聚簇 | `ThoughtTopicClusterEngine` | `lib/discovery.mjs` |
| 起名 / 类别理解 / 写入 / 按批推进 | `ThoughtAutomaticTopicDiscovery` / `ThoughtCategoryBriefMaintainer` | `independent-run.mjs` |
| 限流与重试 | `ThoughtSemanticRetryPolicy` | `lib/backend-client.mjs` |
| 指标 | 方案 §P0.4 | `lib/metrics.mjs` |

其余工具：`run.mjs`（数据集自带主题与答案时的跑批）、`diagnose-invalid.mjs`（看模型原始答卷为什么不合规）、
`rescore.mjs`（按人工标注重新评分）、`summarize.mjs`（结果细看）、`concurrency-probe.mjs`（同题不同并发对照）。

## 指标

| 指标 | 含义 |
|---|---|
| 自动正确率 | Holo 自动归进去的归属里，与东林标注一致的比例 |
| 召回 | 东林认为该归的归属里，被 Holo 覆盖的比例 |
| 待确认率 / 待确认命中率 | 有多少想法会弹出待确认；其中一致的比例 |
| 稳定性 | 同一条想法问 3 轮，每轮结果完全一致的比例 |
| 空归类率 | 东林认为该归、Holo 却一条没归的想法比例 |
| 不该放却被放 | 东林标了「都不该放」的想法里，被归入的比例 |

过程指标用来归因：一条该归的没归上，是**没召回来**（候选里就没有）、**召回了但模型判否**，
还是**判对了但被落库规则截掉**。

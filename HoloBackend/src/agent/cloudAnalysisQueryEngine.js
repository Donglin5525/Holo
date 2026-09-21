/**
 * 云端分析 dynamicPlan 查询引擎（二期 M2a；2026-08-31 对齐修订；2026-09-19 P0 正确性门）
 * 在快照数据集上执行与 iOS 端同协议的声明式查询。
 *
 * 【对齐修订（两轮自审第二轮发现）】输出结构必须与 iOS HoloDynamicQueryEngine
 * 完全同构——提示词按 iOS 端返回格式训练模型，此前自造结构（id@group 等）
 * 模型读不懂，导致复合问题陷入重复查询循环直到轮次耗尽。逐字段对齐：
 * - metricKey = "dynamic.{sanitize(source)}.{sanitize(id)}.{sanitize(group)}"
 *   （sanitize：小写 + 非字母数字→下划线；无分组 group="all"）
 * - formula = "{operation}({field|rows})"；value 四舍五入 4 位小数
 * - comparison：分组 key；"all" 时为 null
 * - events[].excerpt = "动态计算 {metricKey}（{group}）：{value} {unit}；公式：{formula}；来源 {n} 条"
 * - 顶层为 HoloDataToolResult 同构：{toolRequestID, tool, status, coverage, metrics, events, warnings, error}
 * - 错误也走同构结构（status=error + error{code,message,recoverable}），不另造包装
 *
 * 【2026-09-19 P0 正确性门（深度分析提示词与证据链落地方案 任务1）】
 * 此前引擎只对 groupBy.type=field 分组、完全不消费 plan.timeRange、静默丢弃
 * derivations 与 baseline——「查九月混进八月」「按月比较变成全窗口总计」「对比
 * 派生静默消失」三个实锤缺口的根治，全部与 iOS HoloDataTool 同构：
 * - timeRange 真过滤：先按行时间落窗过滤再聚合，半开区间 [start,end)；
 *   end=min(请求end, 快照截止)，未来数据不进历史结论。start/end 接受 Unix
 *   秒或毫秒（≥1e11 视为毫秒），桶与范围标签都从冻结窗口生成。
 * - 分组补全：day/week/month/weekend 此前静默落进 "all" 桶，现输出
 *   yyyy-MM-dd / yyyy-Www（ISO 周）/ yyyy-MM / weekend|weekday / 字段值。
 * - baseline 与派生落地：baseline 为对照窗口（模型未填且派生需要时自动取
 *   同长度前移窗口，iOS HoloDynamicQueryRangeResolver 同构）；
 *   difference/ratio/percentageChange/rate/perDay 确定性计算（此前静默丢弃）。
 * - expression/linearTrend/coverage 维持 NOT_SUPPORTED（能力目录同步声明，
 * 不靠报错文本之外的任何暗示）。
 *
 * 【_search 虚拟字段（2026-09-09 根治）】提示词 v19 教模型用 _search 做跨字段
 * 关键词检索，但该字段从未在任何引擎实现，云端静默返回空导致「账里没记录」
 * 误报。现实现为「目录声明为 text 的全部字段拼接匹配」，并新增未知字段校验：
 * 未声明字段一律返回 UNKNOWN_FIELD（可恢复），不再静默当空值。
 */

/** 行时间戳（毫秒）。occurredAt 是快照组装器保证的身份证字段；旧测试夹具与
 * 早期快照可能只有 date 字段，按声明字段兜底。无法解析返回 null。 */
function rowTimeMs(row) {
  const raw = row?.occurredAt ?? row?.date ?? null;
  if (raw == null) return null;
  const parsed = Date.parse(String(raw));
  return Number.isFinite(parsed) ? parsed : null;
}

/** 模型给出的时间戳归一到毫秒：≥1e11 视为毫秒（2001-09 起），否则视为 Unix 秒。
 * 量纲不可信（<1e8，早于 1973）返回 null，交给调用方按「无窗口」处理。 */
function timestampToMs(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return null;
  if (n >= 1e11) return n;
  if (n >= 1e8) return n * 1000;
  return null;
}

/** ISO 周键 yyyy-Www（与 iOS calendar.dateComponents([yearForWeekOfYear, weekOfYear]) 同构）。 */
function isoWeekKey(date) {
  const d = new Date(date);
  const day = d.getUTCDay() || 7; // 1..7 = 周一..周日
  d.setUTCDate(d.getUTCDate() + 4 - day); // 本 ISO 周的周四
  const year = d.getUTCFullYear();
  const week = Math.ceil(((d.getTime() - Date.UTC(year, 0, 1)) / 86_400_000 + 1) / 7);
  return `${String(year).padStart(4, "0")}-W${String(week).padStart(2, "0")}`;
}

/** 本地日期 "YYYY-MM-DD" → 周几（0=周日…6=周六）。用 UTC 构造承载日期数学，
 * 结果与运行环境时区无关。 */
function localWeekdayOf(dateStr) {
  const [y, m, d] = dateStr.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

/** 本地日期 "YYYY-MM-DD" → ISO 周键。 */
function isoWeekKeyOfDate(dateStr) {
  const [y, m, d] = dateStr.split("-").map(Number);
  return isoWeekKey(new Date(Date.UTC(y, m - 1, d)));
}

/** 行 → 分组键（与 iOS HoloDataTool.buckets 同构，按用户本地日历分桶）。
 * 时间桶直接切时间值字符串的本地部分（带时区偏移的 ISO 前缀即本地日期，
 * 如 2026-09-22T01:00:00+08:00 的本地日期是 09-22）——不经 Date→toISOString
 * 的 UTC 往返，否则东八区凌晨交易会被切进前一天（既有错日缺陷，本次根治）。
 * 纯日期值（旧快照无时刻成分）hour 桶落 "unknown"，模型按能力声明绕行时段分析。 */
function bucketKeyFor(row, grouping) {
  if (!grouping || grouping.type !== "field") {
    switch (grouping?.type) {
      case "day":
      case "week":
      case "month":
      case "weekend":
      case "hour": {
        const raw = String(row?.occurredAt ?? row?.date ?? "");
        if (!/^\d{4}-\d{2}-\d{2}/.test(raw)) return "unknown";
        const localDate = raw.slice(0, 10);
        if (grouping.type === "day") return localDate;
        if (grouping.type === "month") return localDate.slice(0, 7);
        if (grouping.type === "week") return isoWeekKeyOfDate(localDate);
        if (grouping.type === "weekend") {
          const wd = localWeekdayOf(localDate);
          return (wd === 0 || wd === 6) ? "weekend" : "weekday";
        }
        const t = raw.indexOf("T");
        if (t < 0) return "unknown"; // 纯日期旧快照：无时刻成分，时段不可判
        const hh = raw.slice(t + 1, t + 3);
        return /^\d{2}$/.test(hh) ? hh : "unknown";
      }
      default: return "all";
    }
  }
  return String(row[grouping.field] ?? "unknown");
}

export function createCloudAnalysisQueryEngine() {

  function sanitize(value) {
    return String(value ?? "").toLowerCase().replace(/[^a-z0-9]/g, "_");
  }

  function rounded(value) {
    return Math.round(value * 10_000) / 10_000;
  }

  function coerceNumber(value) {
    if (typeof value === "number") return value;
    if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) {
      return Number(value);
    }
    return null;
  }

  function compareByKind(a, b) {
    const ta = Date.parse(a);
    const tb = Date.parse(b);
    if (Number.isFinite(ta) && Number.isFinite(tb)) return ta - tb;
    const na = coerceNumber(a);
    const nb = coerceNumber(b);
    if (na != null && nb != null) return na - nb;
    return String(a).localeCompare(String(b));
  }

  /**
   * _search 虚拟字段的可搜索范围：目录声明为 text 的全部字段
   * （财务域即 分类/账户/备注合并文本/项目——提示词 v19 承诺的「分类、备注、商户、标签」）。
   * iOS 端 HoloDataTool 按 row.fields 里 .text 值拼接，语义一致。
   */
  function searchableFields(dataset) {
    return (dataset.fields ?? [])
      .filter((f) => f.type === "text")
      .map((f) => f.name);
  }

  /**
   * 过滤字段校验。未知字段此前被静默当空值处理，模型把「字段拼错」误读成
   * 「账里没数据」并言之凿凿下结论（2026-09-09 猫砂补货误报根因）——
   * 必须显式报错让模型换路。_search 仅允许 contains（跨字段关键词检索的唯一用法）。
   */
  function validateFilters(filters, dataset, path) {
    const declared = new Set((dataset.fields ?? []).map((f) => f.name));
    for (const filter of filters ?? []) {
      const field = filter?.field;
      if (field === "_search") {
        if (filter.operation !== "contains") {
          return {
            code: "INVALID_PARAMS",
            message: `${path}：_search 仅支持 contains（跨字段关键词检索）`,
            recoverable: true,
          };
        }
        continue;
      }
      if (!declared.has(field)) {
        return {
          code: "UNKNOWN_FIELD",
          message: `${path}：数据集没有字段 ${field}（可用字段：${[...declared].join("、")}；跨字段关键词搜索用 _search）`,
          recoverable: true,
        };
      }
    }
    return null;
  }

  function filterPasses(row, filter, searchFields) {
    const expected = filter.value?.number ?? filter.value?.text ?? filter.value?.date
      ?? filter.value?.boolean ?? null;
    if (filter.field === "_search") {
      const haystack = searchFields.map((name) => String(row[name] ?? "")).join(" ");
      return haystack.includes(String(expected ?? ""));
    }
    const actual = row[filter.field];
    switch (filter.operation) {
      case "equal": return compareByKind(actual, expected) === 0;
      case "notEqual": return compareByKind(actual, expected) !== 0;
      case "greaterThan": return compareByKind(actual, expected) > 0;
      case "greaterThanOrEqual": return compareByKind(actual, expected) >= 0;
      case "lessThan": return compareByKind(actual, expected) < 0;
      case "lessThanOrEqual": return compareByKind(actual, expected) <= 0;
      case "contains": return String(actual ?? "").includes(String(expected ?? ""));
      case "oneOf": {
        const options = Array.isArray(filter.value?.oneOf) ? filter.value.oneOf : null;
        if (!options) return false;
        return options.some((option) => {
          const optValue = option?.number ?? option?.text ?? option?.date ?? option?.boolean ?? null;
          return compareByKind(actual, optValue) === 0;
        });
      }
      default: return false;
    }
  }

  function aggregate(operation, values) {
    const numbers = values.map(coerceNumber).filter((v) => v != null);
    switch (operation) {
      case "count": return values.length;
      // 空集合不产指标（iOS 同构：sum([])=nil 而非 0——「窗口内没数据」与「合计为零」
      // 是两件事，0 会造出精确但错误的数字）
      case "sum": return numbers.length > 0 ? numbers.reduce((a, b) => a + b, 0) : null;
      case "average": return numbers.length > 0 ? numbers.reduce((a, b) => a + b, 0) / numbers.length : null;
      case "min": return numbers.length > 0 ? Math.min(...numbers) : null;
      case "max": return numbers.length > 0 ? Math.max(...numbers) : null;
      case "distinctCount": return values.length > 0 ? new Set(values.map((v) => String(v))).size : null;
      default: return null;
    }
  }

  function toolResultEnvelope(toolRequestID, tool, { status, metrics = [], events = [], warnings = [], error = null }) {
    return { toolRequestID, tool, status, coverage: null, metrics, events, warnings, error };
  }

  /**
   * 行明细查询（snapshot_rows 工具）：dynamicPlan 只有聚合统计，模型看不到
   * 「某笔大额支出的备注」这类记录原文——归因类问题的必备证据。按过滤器取样、
   * 可排序、限量，返回匹配行的人话摘录（行内 excerpt 优先，缺省拼前几个字段值）。
   * parameters 经 validateAgentLoopContent 规范化后值全是字符串（iOS [String:String] 约定），
   * 数组/数字字段在此归一化回结构。
   */
  function normalizeRowsPlan(raw) {
    const plan = { ...raw };
    if (typeof plan.filters === "string") {
      try { plan.filters = JSON.parse(plan.filters); } catch { plan.filters = []; }
    }
    if (typeof plan.limit === "string") {
      const parsed = Number(plan.limit);
      plan.limit = Number.isFinite(parsed) ? parsed : undefined;
    }
    return plan;
  }

  function sampleRows(rawPlan, snapshot, context = {}) {
    const plan = normalizeRowsPlan(rawPlan);
    const toolRequestID = context.toolRequestID ?? "rows";
    const tool = context.tool ?? "snapshot_rows";
    const dataset = snapshot?.datasets?.[plan.source];
    if (!dataset) {
      return toolResultEnvelope(toolRequestID, tool, {
        status: "error",
        error: {
          code: "INVALID_DATASET",
          message: `快照中没有数据集 ${plan.source}（云端可用：${Object.keys(snapshot?.datasets ?? {}).join("、 ") || "无"}）`,
          recoverable: true,
        },
      });
    }
    let rows = dataset.rows ?? [];
    const filterError = validateFilters(plan.filters, dataset, "filters");
    if (filterError) {
      return toolResultEnvelope(toolRequestID, tool, { status: "error", error: filterError });
    }
    const searchFields = searchableFields(dataset);
    for (const filter of plan.filters ?? []) {
      rows = rows.filter((row) => filterPasses(row, filter, searchFields));
    }
    if (plan.sortBy) {
      const field = plan.sortBy;
      rows = [...rows].sort((a, b) => plan.sortDirection === "ascending"
        ? compareByKind(a[field], b[field])
        : compareByKind(b[field], a[field]));
    }
    const limit = Math.min(Math.max(Number(plan.limit) || 5, 1), 10);
    const fieldNames = (dataset.fields ?? []).map((f) => f.name);
    const events = rows.slice(0, limit).map((row, index) => ({
      id: `rows-${sanitize(plan.source)}-${index}`,
      dataset: plan.source,
      excerpt: typeof row.excerpt === "string" && row.excerpt.trim() !== ""
        ? row.excerpt
        : rowExcerpt(row, fieldNames),
    }));
    if (events.length === 0) {
      return toolResultEnvelope(toolRequestID, tool, {
        status: "empty",
        warnings: [{ code: "NO_MATCHING_DATA", message: "过滤后没有匹配的数据行" }],
      });
    }
    return toolResultEnvelope(toolRequestID, tool, { status: "success", metrics: [], events });
  }

  /** 行摘录兜底：行没有现成 excerpt 时按字段定义顺序拼前 4 个非空值。 */
  function rowExcerpt(row, fieldNames) {
    const parts = [];
    for (const name of fieldNames) {
      const value = row[name];
      if (value == null || String(value).trim() === "") continue;
      parts.push(String(value));
      if (parts.length >= 4) break;
    }
    return parts.join(" ");
  }

  /** 归一化 timeRange/baseline 为毫秒窗口；字段缺失或量纲不可信返回 null。 */
  function windowOf(range) {
    if (!range || typeof range !== "object") return null;
    const startMs = timestampToMs(range.start);
    const endMs = timestampToMs(range.end);
    if (startMs == null || endMs == null || startMs >= endMs) return null;
    return { label: typeof range.label === "string" ? range.label : "", startMs, endMs };
  }

  /** 快照截止：iOS 组装器的 generatedAt（ISO8601）。历史查询不得越过它。 */
  function snapshotCutoffMs(snapshot) {
    const parsed = Date.parse(snapshot?.generatedAt ?? "");
    return Number.isFinite(parsed) ? parsed : null;
  }

  /** 模型传入的原始时间窗值的安全序列化（错误消息回显用），截断防刷屏。 */
  function describeRawRange(range) {
    try {
      const text = JSON.stringify(range) ?? String(range);
      return text.length > 120 ? `${text.slice(0, 120)}…` : text;
    } catch {
      return String(range);
    }
  }

  /**
   * 时间窗口显式校验（2026-09-21 静默失效根治）：模型显式给了 timeRange/baseline
   * 但 windowOf 解析失败（日期文本而非 Unix 秒/毫秒、start≥end）时，此前静默当作
   * 「无窗口」返回全量——模型看到数字与未过滤完全一致，只能在报告里承认「时间
   * 过滤没有生效」（2026-09-21 东林「最近一个季度」追问 538 笔全量作答实锤）。
   * 与 _search/UNKNOWN_FIELD 同一教训：认不出必须显式报错让模型换格式重试，
   * 不做静默降级。perDay 派生依赖 timeRange，缺窗口同样显式报错（此前派生
   * 静默消失）。
   */
  function validateWindows(plan, snapshot) {
    const cutoffMs = snapshotCutoffMs(snapshot);
    const formatHint = cutoffMs != null
      ? `start/end 必须是 Unix 秒（如 ${Math.floor(cutoffMs / 1000)}）或 Unix 毫秒数字，不能是日期文本，且 start 必须早于 end；快照截止 end=${Math.floor(cutoffMs / 1000)}（Unix 秒）可直接引用。`
      : "start/end 必须是 Unix 秒或 Unix 毫秒数字，不能是日期文本，且 start 必须早于 end。";
    if (plan.timeRange != null && !windowOf(plan.timeRange)) {
      return {
        code: "INVALID_TIMERANGE",
        message: `timeRange 无法解析（收到 ${describeRawRange(plan.timeRange)}）。${formatHint}`,
        recoverable: true,
      };
    }
    if (plan.baseline != null && !windowOf(plan.baseline)) {
      return {
        code: "INVALID_TIMERANGE",
        message: `baseline 对照窗口无法解析（收到 ${describeRawRange(plan.baseline)}）。${formatHint}`,
        recoverable: true,
      };
    }
    const needsPerDayWindow = (plan.derivations ?? []).some((d) => d?.operation === "perDay");
    if (needsPerDayWindow && plan.timeRange == null) {
      return {
        code: "INVALID_TIMERANGE",
        message: "perDay 派生需要显式 timeRange（按窗口天数折算日均），请补全后重试。",
        recoverable: true,
      };
    }
    return null;
  }


  /** 窗口的可读描述（错误/警告文案用）。 */
  function describeWindow(window) {
    if (!window) return "无";
    const fmt = (ms) => new Date(ms).toISOString().slice(0, 10);
    return `${fmt(window.startMs)}~${fmt(window.endMs)}${window.label ? `（${window.label}）` : ""}`;
  }

  /** 派生需要对照窗而模型未填时，自动取同长度前移窗口（iOS baselineIfNeeded 同构）。 */
  function autoBaselineWindow(plan) {
    if (windowOf(plan.baseline)) return windowOf(plan.baseline);
    const needsBaseline = (plan.derivations ?? []).some((d) =>
      ["difference", "ratio", "percentageChange"].includes(d?.operation));
    const current = windowOf(plan.timeRange);
    if (!needsBaseline || !current) return null;
    const duration = current.endMs - current.startMs;
    return { label: "前一对比期", startMs: current.startMs - duration, endMs: current.startMs };
  }

  /**
   * 执行一条 dynamicPlan，返回 iOS HoloDataToolResult 同构结构。
   */
  function execute(plan, snapshot, context = {}) {
    const toolRequestID = context.toolRequestID ?? "dynamic";
    const tool = context.tool ?? plan.source ?? "unknown";
    const dataset = snapshot?.datasets?.[plan.source];

    const unsupported = (plan.derivations ?? []).map((d) => d.operation)
      .find((op) => ["expression", "linearTrend", "coverage"].includes(op));
    if (unsupported) {
      return toolResultEnvelope(toolRequestID, tool, {
        status: "error",
        error: {
          code: "NOT_SUPPORTED_BY_CLOUD",
          message: `云端暂不支持 ${unsupported}，请改用基础聚合（count/sum/average/min/max/distinctCount）+ 分组/时间窗组合完成分析`,
          recoverable: true,
        },
      });
    }
    if (!dataset) {
      return toolResultEnvelope(toolRequestID, tool, {
        status: "error",
        error: {
          code: "INVALID_DATASET",
          message: `快照中没有数据集 ${plan.source}（云端可用：${Object.keys(snapshot?.datasets ?? {}).join("、 ") || "无"}）`,
          recoverable: true,
        },
      });
    }

    const windowError = validateWindows(plan, snapshot);
    if (windowError) {
      return toolResultEnvelope(toolRequestID, tool, { status: "error", error: windowError });
    }

    const filterError = validateFilters(plan.filters, dataset, "filters")
      ?? (plan.aggregations ?? []).reduce(
        (err, agg, index) => err ?? validateFilters(agg.filters, dataset, `aggregations[${index}].filters`),
        null,
      );
    if (filterError) {
      return toolResultEnvelope(toolRequestID, tool, { status: "error", error: filterError });
    }

    const searchFields = searchableFields(dataset);
    let rows = dataset.rows ?? [];
    for (const filter of plan.filters ?? []) {
      rows = rows.filter((row) => filterPasses(row, filter, searchFields));
    }

    // 时间过滤（P0 核心）：先过滤再聚合；end=min(请求end, 快照截止)，未来数据
    // （未发生分期/待办）不得进入已发生的历史结论。无 timeRange = 不过滤
    // （旧协议兼容，快照本身已限 180 天窗）。
    // baseSource = 字段过滤后、时间过滤前的行——对照窗口从它筛，否则当前窗
    // 先把对照期行滤掉，baseline 永远为空。
    const cutoffMs = snapshotCutoffMs(snapshot);
    const currentWindow = windowOf(plan.timeRange);
    const baseSource = rows;
    if (currentWindow) {
      const effectiveEnd = cutoffMs != null ? Math.min(currentWindow.endMs, cutoffMs) : currentWindow.endMs;
      rows = rows.filter((row) => {
        const t = rowTimeMs(row);
        return t != null && t >= currentWindow.startMs && t < effectiveEnd;
      });
    }
    const baselineWindow = autoBaselineWindow(plan);
    let baselineRows = [];
    if (baselineWindow) {
      const baselineEnd = cutoffMs != null ? Math.min(baselineWindow.endMs, cutoffMs) : baselineWindow.endMs;
      baselineRows = baseSource.filter((row) => {
        const t = rowTimeMs(row);
        return t != null && t >= baselineWindow.startMs && t < baselineEnd;
      });
    }

    // 分组（iOS 语义：单分组维度；无分组 = "all" 桶；day/week/month/weekend/field 全支持）
    const grouping = plan.groupBy?.[0];
    const bucketOf = (sourceRows) => {
      if (!grouping) return [{ key: "all", rows: sourceRows }];
      const byKey = new Map();
      for (const row of sourceRows) {
        const key = bucketKeyFor(row, grouping);
        if (!byKey.has(key)) byKey.set(key, []);
        byKey.get(key).push(row);
      }
      return [...byKey.entries()]
        .sort((a, b) => a[0].localeCompare(b[0]))
        .map(([key, bucketRows]) => ({ key, rows: bucketRows }));
    };
    const buckets = bucketOf(rows);
    const baselineBuckets = new Map(bucketOf(baselineRows).map((b) => [b.key, b.rows]));

    const metrics = [];
    for (const bucket of buckets) {
      for (const agg of plan.aggregations ?? []) {
        let target = bucket.rows;
        for (const filter of agg.filters ?? []) {
          target = target.filter((row) => filterPasses(row, filter, searchFields));
        }
        const value = agg.operation === "count"
          ? target.length
          : aggregate(agg.operation, target.map((row) => row[agg.field]));
        if (value == null) continue;
        let baselineTarget = baselineBuckets.get(bucket.key) ?? [];
        for (const filter of agg.filters ?? []) {
          baselineTarget = baselineTarget.filter((row) => filterPasses(row, filter, searchFields));
        }
        const baselineValue = baselineWindow && baselineTarget.length > 0
          ? (agg.operation === "count"
            ? baselineTarget.length
            : aggregate(agg.operation, baselineTarget.map((row) => row[agg.field])))
          : null;
        const metricKey = `dynamic.${sanitize(plan.source)}.${sanitize(agg.id)}.${sanitize(bucket.key)}`;
        const formula = `${agg.operation}(${agg.field ?? "rows"})`;
        const sourceRecordIDs = target.slice(0, plan.evidenceLimit ?? 20).map((row) => String(row.id ?? ""));
        metrics.push({
          metricKey,
          dataset: plan.source,
          value: rounded(value),
          unit: agg.unit ?? null,
          baselineValue: baselineValue != null ? rounded(baselineValue) : null,
          comparison: bucket.key === "all" ? null : bucket.key,
          formula,
          sourceRecordIDs,
        });
      }
    }

    // 派生（iOS HoloDataTool.derive 同构）：difference/ratio/percentageChange/rate/perDay
    const derivationMetrics = [];
    for (const derivation of plan.derivations ?? []) {
      const matching = metrics.filter((m) => m.metricKey.includes(`.${sanitize(derivation.metricID)}.`));
      for (const metric of matching) {
        let value = null;
        let formula = "";
        switch (derivation.operation) {
          case "difference":
            if (metric.baselineValue != null) {
              value = (metric.value ?? 0) - metric.baselineValue;
              formula = "current - baseline";
            }
            break;
          case "ratio": {
            const denominator = derivation.denominatorMetricID
              ? metrics.find((m) => m.metricKey.includes(`.${sanitize(derivation.denominatorMetricID)}.`))?.value
              : metric.baselineValue;
            if (denominator != null && denominator !== 0) {
              value = (metric.value ?? 0) / denominator;
              formula = "numerator / denominator";
            }
            break;
          }
          case "percentageChange":
            if (metric.baselineValue != null && metric.baselineValue !== 0) {
              value = ((metric.value ?? 0) - metric.baselineValue) / Math.abs(metric.baselineValue);
              formula = "(current - baseline) / abs(baseline)";
            }
            break;
          case "rate": {
            const denominator = derivation.denominatorMetricID
              ? metrics.find((m) => m.metricKey.includes(`.${sanitize(derivation.denominatorMetricID)}.`))?.value
              : null;
            if (denominator != null && denominator !== 0) {
              value = (metric.value ?? 0) / denominator;
              formula = "count / total";
            }
            break;
          }
          case "perDay": {
            const window = windowOf(plan.timeRange);
            if (window) {
              const days = Math.max(1, Math.round((window.endMs - window.startMs) / 86_400_000));
              value = (metric.value ?? 0) / days;
              formula = `value / calendar_days(${days})`;
            }
            break;
          }
          default:
            break;
        }
        if (value == null) continue;
        const group = metric.comparison ?? "all";
        derivationMetrics.push({
          metricKey: `dynamic.${sanitize(plan.source)}.${sanitize(derivation.id)}.${sanitize(group)}`,
          dataset: plan.source,
          value: rounded(value),
          unit: derivation.unit ?? null,
          baselineValue: null,
          comparison: metric.comparison,
          formula,
          sourceRecordIDs: metric.sourceRecordIDs,
        });
      }
    }
    metrics.push(...derivationMetrics);

    const events = [];
    for (const metric of metrics) {
      const group = metric.comparison ? `（${metric.comparison}）` : "";
      const baselineText = metric.baselineValue != null ? `；对照 ${metric.baselineValue}` : "";
      const valueText = metric.value != null ? String(metric.value) : "无值";
      events.push({
        id: `dynamic-${metric.metricKey}`,
        metricKey: metric.metricKey,
        metricValue: metric.value,
        dataset: plan.source,
        excerpt: `动态计算 ${metric.metricKey}${group}：${valueText} ${metric.unit ?? ""}${baselineText}；公式：${metric.formula}；来源 ${metric.sourceRecordIDs.length} 条`,
        formula: metric.formula,
        sourceRecordIDs: metric.sourceRecordIDs,
      });
    }

    if (metrics.length === 0) {
      // 空结论必须可解释：说清时间窗内多少行、数据集总共多少行、快照截止在哪，
      // 模型才能区分「真没数据」与「时间窗不对」——这是 P0「缺口可解释」的引擎侧。
      const totalRows = dataset.rows?.length ?? 0;
      const windowNote = currentWindow
        ? `；时间窗 ${describeWindow(currentWindow)} 内 0 行（数据集共 ${totalRows} 行，快照截止 ${cutoffMs != null ? new Date(cutoffMs).toISOString().slice(0, 10) : "未知"}）`
        : "";
      return toolResultEnvelope(toolRequestID, tool, {
        status: "empty",
        warnings: [{ code: "NO_MATCHING_DATA", message: `过滤后没有匹配的数据行${windowNote}` }],
      });
    }

    // 排序（iOS 语义：按 metricKey 含 ".{sanitize(metricID)}." 过滤后按值排序）
    if (plan.sort) {
      const needle = `.${sanitize(plan.sort.metricID)}.`;
      const sortable = metrics.filter((m) => m.metricKey.includes(needle));
      const pool = sortable.length > 0 ? sortable : metrics;
      pool.sort((a, b) => (plan.sort.direction === "ascending"
        ? (a.value ?? -Infinity) - (b.value ?? -Infinity)
        : (b.value ?? -Infinity) - (a.value ?? -Infinity)));
      return toolResultEnvelope(toolRequestID, tool, {
        status: "success",
        metrics: pool.slice(0, plan.limit ?? 20),
        events: events.filter((e) => pool.slice(0, plan.limit ?? 20).some((m) => m.metricKey === e.metricKey)),
      });
    }

    const limited = metrics.slice(0, plan.limit ?? 20);
    return toolResultEnvelope(toolRequestID, tool, {
      status: "success",
      metrics: limited,
      events: events.slice(0, plan.limit ?? 20),
    });
  }

  return { execute, sampleRows };
}

/**
 * 从快照生成云端工具目录（模型可用的数据集+字段说明），替代 iOS 端 toolDescriptions。
 * P0 起，目录同时是「能力与边界同一真相源」：明确列出已支持/未支持的能力与
 * 快照时间窗（含可直接复制的 Unix 秒），不靠后置文本覆盖前文相反命令。
 */
export function buildCloudToolCatalog(snapshot) {
  const lines = [];
  const datasets = snapshot?.datasets ?? {};
  for (const [name, dataset] of Object.entries(datasets)) {
    // 字段说明必须进目录：模型不知道 text 是「备注、说明和标签合并文本」，
    // 就永远不会拿备注做归因（2026-08-31 验收：音乐 3316 的「TIMA音乐盛典」备注被漏）。
    const fields = (dataset.fields ?? [])
      .map((f) => `${f.name}:${f.type}${f.unit ? `[${f.unit}]` : ""}${f.description ? `(${f.description})` : ""}`)
      .join(" ");
    const rows = dataset.rows?.length ?? 0;
    lines.push(`【${name}】rows=${rows} fields: ${fields}`);
  }
  const statics = Object.keys(snapshot?.statics ?? {});
  if (statics.length > 0) {
    lines.push(`（预取静态块：${statics.join("、 ")}——query 用同名 tool 名直接取）`);
  }

  const cutoffMs = Date.parse(snapshot?.generatedAt ?? "");
  const cutoffISO = Number.isFinite(cutoffMs) ? new Date(cutoffMs).toISOString() : null;
  const historyDays = Number.isFinite(Number(snapshot?.historyDays)) ? Number(snapshot?.historyDays) : null;
  const windowLines = [];
  if (cutoffISO && historyDays) {
    const startMs = cutoffMs - historyDays * 86_400_000;
    const sec = (ms) => Math.floor(ms / 1000);
    windowLines.push(
      `快照窗口：${new Date(startMs).toISOString().slice(0, 10)} 起，截止 ${cutoffISO}（generatedAt）。`,
      `dynamicPlan.timeRange/baseline 的 start/end 用 Unix 秒：本窗口可直接引用 start=${sec(startMs)}、end=${sec(cutoffMs)}；查询不得超出快照窗口，超出部分没有数据。行时间取 occurredAt 字段。`,
    );
  }
  lines.push(
    "云端能力（已支持）：dynamicPlan 基础聚合 count/sum/average/min/max/distinctCount；字段过滤（含 _search 跨字段关键词）；分组 groupBy 单维 type=field/day/week/month/weekend/hour（hour=按用户本地时刻的 0-23 小时桶，付款时段/夜间消费分析用；若该桶大量返回 unknown 说明快照时间值仅到日、无时刻成分，时段分析不可做，改用其他维度）；timeRange 时间过滤（先过滤再聚合，未来数据不进历史结论）；baseline 对照窗口与派生 difference/ratio/percentageChange/rate/perDay（需要对比而未填 baseline 时系统自动取同长度前移窗口）。",
    "云端能力（未支持，请求即报错换路）：expression/linearTrend/coverage 派生；cross_domain.aligned_analysis；未预取的固定 query；快照窗口外的时间段。跨域问题请分别查询两个数据集的同期分组指标后并列对照，只能表述「同一段时间都变化/并发」，不得表述因果或已对齐的统计关联。",
    "行明细工具 snapshot_rows：聚合统计回答「有多少」，看不到记录原文；归因「这笔钱是什么/为什么大」时必须取样明细——",
    'tool="snapshot_rows", query="rows_sample", parameters={source, filters:[{field,operation,value}], sortBy, sortDirection:"descending"|"ascending", limit}（limit≤10）。',
    "返回匹配行的人话摘录（含备注、内容原文）。例：查音乐分类最大 3 笔支出 → filters:[{field:\"category\",operation:\"equal\",value:{text:\"音乐\"}}], sortBy:\"amount\", sortDirection:\"descending\", limit:3。",
    '关键词跨字段筛选（商品名/品牌/备注词，如"猫砂""烟"）用 _search 虚拟字段，会同时匹配目录中全部文本字段：filters:[{field:"_search",operation:"contains",value:{type:"text",text:"猫砂"}}]。',
  );
  const capabilityBlock = lines.join("\n");
  if (windowLines.length === 0) return `云端工具目录（数据来自设备快照，仅覆盖快照时间窗）：\n${capabilityBlock}`;
  return `云端工具目录（数据来自设备快照，仅覆盖快照时间窗）：\n${windowLines.join("\n")}\n${capabilityBlock}`;
}

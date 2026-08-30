/**
 * 云端分析 dynamicPlan 查询引擎（二期 M2a；2026-08-31 对齐修订）
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
 * M2a 能力边界：expression/linearTrend/coverage/baseline 派生按可恢复错误返回，
 * 模型按协议换路。
 */

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

  function filterPasses(row, filter) {
    const actual = row[filter.field];
    const expected = filter.value?.number ?? filter.value?.text ?? filter.value?.date
      ?? filter.value?.boolean ?? null;
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
      case "sum": return numbers.reduce((a, b) => a + b, 0);
      case "average": return numbers.length > 0 ? numbers.reduce((a, b) => a + b, 0) / numbers.length : null;
      case "min": return numbers.length > 0 ? Math.min(...numbers) : null;
      case "max": return numbers.length > 0 ? Math.max(...numbers) : null;
      case "distinctCount": return new Set(values.map((v) => String(v))).size;
      default: return null;
    }
  }

  function toolResultEnvelope(toolRequestID, tool, { status, metrics = [], events = [], warnings = [], error = null }) {
    return { toolRequestID, tool, status, coverage: null, metrics, events, warnings, error };
  }

  /**
   * 执行一条 dynamicPlan，返回 iOS HoloDataToolResult 同构结构。
   */
  function execute(plan, snapshot, context = {}) {
    const toolRequestID = context.toolRequestID ?? "dynamic";
    const tool = context.tool ?? plan.source ?? "unknown";
    const dataset = snapshot?.datasets?.[plan.source];

    const unsupported = (plan.baseline ? "baseline" : null)
      ?? (plan.derivations ?? []).map((d) => d.operation)
        .find((op) => ["expression", "linearTrend", "coverage"].includes(op));
    if (unsupported) {
      return toolResultEnvelope(toolRequestID, tool, {
        status: "error",
        error: {
          code: "NOT_SUPPORTED_BY_CLOUD",
          message: `云端暂不支持 ${unsupported}，请改用基础聚合（count/sum/average/min/max/distinctCount）组合完成分析`,
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

    let rows = dataset.rows ?? [];
    for (const filter of plan.filters ?? []) {
      rows = rows.filter((row) => filterPasses(row, filter));
    }

    // 分组（iOS 语义：单分组维度；无分组 = "all" 桶）
    const grouping = plan.groupBy?.[0];
    let buckets;
    if (!grouping || grouping.type !== "field" || !grouping.field) {
      buckets = [{ key: "all", rows }];
    } else {
      const byKey = new Map();
      for (const row of rows) {
        const key = String(row[grouping.field] ?? "unknown");
        if (!byKey.has(key)) byKey.set(key, []);
        byKey.get(key).push(row);
      }
      buckets = [...byKey.entries()]
        .sort((a, b) => a[0].localeCompare(b[0]))
        .map(([key, bucketRows]) => ({ key, rows: bucketRows }));
    }

    const metrics = [];
    const events = [];
    for (const bucket of buckets) {
      for (const agg of plan.aggregations ?? []) {
        let target = bucket.rows;
        for (const filter of agg.filters ?? []) {
          target = target.filter((row) => filterPasses(row, filter));
        }
        const value = agg.operation === "count"
          ? target.length
          : aggregate(agg.operation, target.map((row) => row[agg.field]));
        if (value == null) continue;
        const metricKey = `dynamic.${sanitize(plan.source)}.${sanitize(agg.id)}.${sanitize(bucket.key)}`;
        const formula = `${agg.operation}(${agg.field ?? "rows"})`;
        const sourceRecordIDs = target.slice(0, plan.evidenceLimit ?? 20).map((row) => String(row.id ?? ""));
        metrics.push({
          metricKey,
          value: rounded(value),
          unit: agg.unit ?? null,
          baselineValue: null,
          comparison: bucket.key === "all" ? null : bucket.key,
          formula,
          sourceRecordIDs,
        });
      }
    }

    for (const metric of metrics) {
      const group = metric.comparison ? `（${metric.comparison}）` : "";
      const valueText = metric.value != null ? String(metric.value) : "无值";
      events.push({
        id: `dynamic-${metric.metricKey}`,
        metricKey: metric.metricKey,
        metricValue: metric.value,
        excerpt: `动态计算 ${metric.metricKey}${group}：${valueText} ${metric.unit ?? ""}；公式：${metric.formula}；来源 ${metric.sourceRecordIDs.length} 条`,
        formula: metric.formula,
        sourceRecordIDs: metric.sourceRecordIDs,
      });
    }

    if (metrics.length === 0) {
      return toolResultEnvelope(toolRequestID, tool, {
        status: "empty",
        warnings: [{ code: "NO_MATCHING_DATA", message: "过滤后没有匹配的数据行" }],
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

  return { execute };
}

/** 从快照生成云端工具目录（模型可用的数据集+字段说明），替代 iOS 端 toolDescriptions。 */
export function buildCloudToolCatalog(snapshot) {
  const lines = [];
  const datasets = snapshot?.datasets ?? {};
  for (const [name, dataset] of Object.entries(datasets)) {
    const fields = (dataset.fields ?? [])
      .map((f) => `${f.name}:${f.type}${f.unit ? `[${f.unit}]` : ""}`)
      .join(" ");
    const rows = dataset.rows?.length ?? 0;
    lines.push(`【${name}】rows=${rows} fields: ${fields}`);
  }
  const statics = Object.keys(snapshot?.statics ?? {});
  if (statics.length > 0) {
    lines.push(`（预取静态块：${statics.join("、 ")}——query 用同名 tool 名直接取）`);
  }
  return `云端工具目录（数据来自设备快照，仅覆盖快照时间窗）：\n${lines.join("\n")}`;
}

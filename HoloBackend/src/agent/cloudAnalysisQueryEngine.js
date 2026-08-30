/**
 * 云端分析 dynamicPlan 查询引擎（二期 M2a）
 * 在快照数据集（iOS 发起时聚合的行数据）上执行与 iOS 端同协议的声明式查询：
 * filter(equal/notEqual/greaterThan[OrEqual]/lessThan[OrEqual]/contains/oneOf)
 * → groupBy → aggregation(count/sum/average/min/max/distinctCount)
 * → derivation(difference/ratio/percentageChange/rate)
 * → sort/limit/evidenceLimit。
 * 协议规范以 agentLoop 提示词模板为准（typed value、字段目录、合法操作枚举）。
 * M2a 能力边界：expression/linearTrend/coverage/baseline 明确返回 NOT_SUPPORTED_BY_CLOUD，
 * 模型会按协议降级换路——诚实的能力边界优于静默的错误实现。
 */

export function createCloudAnalysisQueryEngine() {

  /** typed value → JS 值；行字段按 dataset.fields 声明的类型解析 */
  function fieldAccessor(fields) {
    const byName = new Map(fields.map((f) => [f.name, f]));
    return {
      type(name) {
        return byName.get(name)?.type ?? null;
      },
      value(row, name) {
        return row[name];
      },
    };
  }

  function coerceNumber(value) {
    if (typeof value === "number") return value;
    if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) {
      return Number(value);
    }
    return null;
  }

  function compareByKind(a, b, type) {
    if (type === "date" || (typeof a === "string" && typeof b === "string" && type !== "text")) {
      const ta = Date.parse(a);
      const tb = Date.parse(b);
      if (Number.isFinite(ta) && Number.isFinite(tb)) return ta - tb;
    }
    const na = coerceNumber(a);
    const nb = coerceNumber(b);
    if (na != null && nb != null) return na - nb;
    return String(a).localeCompare(String(b));
  }

  function filterPasses(row, filter, fields) {
    const field = fields.find((f) => f.name === filter.field);
    const actual = row[filter.field];
    const expected = filter.value?.number ?? filter.value?.text ?? filter.value?.date
      ?? filter.value?.boolean ?? null;
    const type = field?.type ?? (filter.value?.type ?? "text");
    switch (filter.operation) {
      case "equal":
        return compareByKind(actual, expected, type) === 0;
      case "notEqual":
        return compareByKind(actual, expected, type) !== 0;
      case "greaterThan":
        return compareByKind(actual, expected, type) > 0;
      case "greaterThanOrEqual":
        return compareByKind(actual, expected, type) >= 0;
      case "lessThan":
        return compareByKind(actual, expected, type) < 0;
      case "lessThanOrEqual":
        return compareByKind(actual, expected, type) <= 0;
      case "contains":
        return String(actual ?? "").includes(String(expected ?? ""));
      case "oneOf": {
        const options = Array.isArray(filter.value?.oneOf) ? filter.value.oneOf : null;
        if (!options) return false;
        return options.some((option) => {
          const optValue = option?.number ?? option?.text ?? option?.date ?? option?.boolean ?? null;
          return compareByKind(actual, optValue, type) === 0;
        });
      }
      default:
        return false;
    }
  }

  function aggregate(operation, values) {
    const numbers = values.map(coerceNumber).filter((v) => v != null);
    switch (operation) {
      case "count":
        return values.length;
      case "sum":
        return numbers.reduce((a, b) => a + b, 0);
      case "average":
        return numbers.length > 0 ? numbers.reduce((a, b) => a + b, 0) / numbers.length : null;
      case "min":
        return numbers.length > 0 ? Math.min(...numbers) : null;
      case "max":
        return numbers.length > 0 ? Math.max(...numbers) : null;
      case "distinctCount":
        return new Set(values.map((v) => String(v))).size;
      default:
        return null;
    }
  }

  /**
   * 执行一条 dynamicPlan。
   * @param {object} plan dynamicPlan（协议字段）
   * @param {object} snapshot 快照：{ version, datasets: { name: { fields, rows } } }
   * @returns {{ metrics: object[], evidence: object[], groupRows: object[] }}
   */
  function execute(plan, snapshot) {
    const dataset = snapshot?.datasets?.[plan.source];
    if (!dataset) {
      return error(`INVALID_DATASET: 快照中没有数据集 ${plan.source}（云端可用：${Object.keys(snapshot?.datasets ?? {}).join(", ") || "无"}）`);
    }
    if (plan.baseline || (plan.derivations ?? []).some((d) => ["expression", "linearTrend", "coverage"].includes(d.operation))) {
      return error("NOT_SUPPORTED_BY_CLOUD: baseline/expression/linearTrend/coverage 派生暂不支持，请改用基础聚合组合完成分析");
    }

    let rows = dataset.rows ?? [];
    for (const filter of plan.filters ?? []) {
      rows = rows.filter((row) => filterPasses(row, filter, dataset.fields ?? []));
    }

    const groupFields = plan.groupBy?.map((g) => g.field) ?? [];
    let groups;
    if (groupFields.length === 0) {
      groups = [{ key: null, rows }];
    } else {
      const byKey = new Map();
      for (const row of rows) {
        const key = groupFields.map((f) => String(row[f] ?? "∅")).join(" | ");
        if (!byKey.has(key)) byKey.set(key, { key, keyValues: Object.fromEntries(groupFields.map((f) => [f, row[f]])), rows: [] });
        byKey.get(key).rows.push(row);
      }
      groups = [...byKey.values()];
    }

    const metrics = [];
    const evidence = [];
    for (const group of groups) {
      for (const agg of plan.aggregations ?? []) {
        let target = group.rows;
        for (const filter of agg.filters ?? []) {
          target = target.filter((row) => filterPasses(row, filter, dataset.fields ?? []));
        }
        const value = agg.operation === "count"
          ? target.length
          : aggregate(agg.operation, target.map((row) => row[agg.field]));
        metrics.push({
          id: groups.length > 1 && agg.id ? `${agg.id}@${group.key ?? ""}` : agg.id,
          group: group.keyValues ?? null,
          operation: agg.operation,
          field: agg.field ?? null,
          unit: agg.unit ?? null,
          value,
        });
      }
      // 证据行：每组附样例行（evidenceLimit 控制总量），带行号供模型引用
      const limitPerGroup = Math.max(1, Math.ceil((plan.evidenceLimit ?? 20) / Math.max(groups.length, 1)));
      group.rows.slice(0, limitPerGroup).forEach((row, index) => {
        evidence.push({
          dataset: plan.source,
          group: group.key ?? null,
          rowIndex: index,
          row,
        });
      });
    }

    for (const derivation of plan.derivations ?? []) {
      const findMetric = (id) => metrics.find((m) => m.id === id || m.id?.startsWith(`${id}@`))?.value;
      const a = findMetric(derivation.metrics?.[0] ?? derivation.metricA ?? "");
      const b = findMetric(derivation.metrics?.[1] ?? derivation.metricB ?? "");
      let value = null;
      switch (derivation.operation) {
        case "difference":
          value = a != null && b != null ? a - b : null;
          break;
        case "ratio":
          value = a != null && b != null && b !== 0 ? a / b : null;
          break;
        case "percentageChange":
          value = a != null && b != null && b !== 0 ? ((a - b) / b) * 100 : null;
          break;
        case "rate":
          value = a != null && b != null && b !== 0 ? a / b : null;
          break;
        default:
          value = null;
      }
      metrics.push({ id: derivation.id, operation: derivation.operation, value });
    }

    if (plan.sort) {
      const field = plan.sort.field ?? plan.sort.by;
      const direction = (plan.sort.direction ?? plan.sort.order) === "desc" ? -1 : 1;
      metrics.sort((x, y) => {
        const ax = x.group?.[field] ?? x.value;
        const ay = y.group?.[field] ?? y.value;
        return compareByKind(ax, ay) * direction;
      });
    }

    return {
      dataset: plan.source,
      matchedRowCount: rows.length,
      metrics: metrics.slice(0, plan.limit ?? 20),
      evidence: evidence.slice(0, plan.evidenceLimit ?? 20),
    };
  }

  function error(message) {
    return { error: message };
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

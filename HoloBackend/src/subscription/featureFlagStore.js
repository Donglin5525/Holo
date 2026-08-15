// feature_flags：服务端可控的客户端行为开关（P2 路由急停）。
// 值经 GET /v1/subscription/status 的 featureFlags 字段下发；admin 后台可改，改完即生效（不发版）。
// 默认值在 DEFAULT_FLAGS 里声明——新开关必须在此登记，防「表里有值但客户端不认识」。

/** 客户端可识别的开关及其出厂默认值 */
export const DEFAULT_FLAGS = {
  // 意图识别 query_analysis/flexible_data_query 走本地 Agent 的总闸（false=回到纯 chat 链路，急停用）
  agentDeepAnalysis: true,
};

export function createFeatureFlagStore(db) {
  const readAll = db.prepare("SELECT flag, enabled FROM feature_flags");
  const upsert = db.prepare(
    "INSERT INTO feature_flags (flag, enabled, updated_at) VALUES (?, ?, datetime('now')) " +
      "ON CONFLICT(flag) DO UPDATE SET enabled = excluded.enabled, updated_at = datetime('now')"
  );

  function getAll() {
    const overrides = new Map(readAll.all().map((row) => [row.flag, row.enabled === 1]));
    // 出厂默认值 + 表覆盖：表里只存与默认不同或显式改过的值
    const result = {};
    for (const [flag, defaultValue] of Object.entries(DEFAULT_FLAGS)) {
      result[flag] = overrides.has(flag) ? overrides.get(flag) : defaultValue;
    }
    return result;
  }

  function listWithMeta() {
    const overrides = new Map(readAll.all().map((row) => [row.flag, row.enabled === 1]));
    return Object.entries(DEFAULT_FLAGS).map(([flag, defaultValue]) => ({
      flag,
      defaultValue,
      enabled: overrides.has(flag) ? overrides.get(flag) : defaultValue,
      overridden: overrides.has(flag),
    }));
  }

  function set(flag, enabled) {
    if (!(flag in DEFAULT_FLAGS)) {
      throw new Error(`未知开关: ${flag}`);
    }
    upsert.run(flag, enabled ? 1 : 0);
  }

  return { getAll, listWithMeta, set };
}

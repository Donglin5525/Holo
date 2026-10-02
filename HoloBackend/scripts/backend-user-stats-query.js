// Holo 后端用户量统计 —— 由 backend-user-stats.sh 通过 SSH 管道送进 holo-backend 容器执行
// 只读打开生产库。所有「天」均按北京时间（UTC+8）切，与体感日期一致。
// 口径：device_id 是每次安装生成的 UUID，重装/多设备各算一台；「外部」= 剔除内部 Plus
// 白名单设备 + e2e 测试机 + 空设备号（健康检查/爬虫）。
const db = require('better-sqlite3')('/data/holo-backend.db', { readonly: true });

const all = (sql, params = []) => db.prepare(sql).all(...params);
const get = (sql, params = []) => db.prepare(sql).get(...params);

const internalIds = all(`SELECT device_id FROM subscription_acceptance_overrides`).map(r => r.device_id);
const isInternal = (id) => internalIds.includes(id);
const mask = (id) => (id ? id.slice(0, 8) + '…' : '(空)');

const internalNotIn = internalIds.length
  ? ` AND device_id NOT IN (${internalIds.map(() => '?').join(',')})`
  : '';
const externalFilter = `device_id IS NOT NULL AND device_id != '' AND device_id NOT LIKE 'e2e-%'${internalNotIn}`;
// 外部设备去重表达式（CASE 内 NULL 不计入 COUNT DISTINCT）
const extDevExpr =
  `COUNT(DISTINCT CASE WHEN (device_id IS NULL OR device_id = '' OR device_id LIKE 'e2e-%'` +
  (internalIds.length ? ` OR device_id IN (${internalIds.map(() => '?').join(',')})` : '') +
  `) THEN NULL ELSE device_id END)`;

const range = get(`SELECT MIN(created_at) mn, MAX(created_at) mx FROM ai_call_logs`);

console.log('════════════════════════════════════════════════════');
console.log(' Holo 后端用户量报表（AI 功能口径）');
console.log(` 生成时间 ${new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' })}`);
console.log(` 日志覆盖 ${range.mn} ~ ${range.mx}（UTC）`);
console.log(` 内部白名单设备 ${internalIds.length} 台（已剔除出「外部」）`);
console.log('════════════════════════════════════════════════════');

// ── 1. 各时间窗口去重设备数 ────────────────────────────────
console.log('\n【1】去重设备数（窗口内用过 ≥1 次 AI 功能）');
console.log('  窗口        全部设备   外部设备');
const windows = [
  ['近24小时', '-1 day'],
  ['近3天', '-3 days'],
  ['近7天', '-7 days'],
  ['近14天', '-14 days'],
  ['近30天', '-30 days'],
  ['全部历史', null],
];
for (const [label, offset] of windows) {
  const where = offset ? `WHERE created_at >= datetime('now', '${offset}')` : '';
  const total = get(`SELECT COUNT(DISTINCT device_id) n FROM ai_call_logs ${where}`).n;
  const whereExt = offset ? `${where} AND ${externalFilter}` : `WHERE ${externalFilter}`;
  const ext = get(`SELECT COUNT(DISTINCT device_id) n FROM ai_call_logs ${whereExt}`, internalIds).n;
  console.log(`  ${label.padEnd(6)}     ${String(total).padStart(4)}      ${String(ext).padStart(4)}`);
}

// ── 2. 近30天日活趋势（北京时间）──────────────────────────
console.log('\n【2】近30天日活（按北京时间日切；外部=剔除内部设备）');
console.log('  日期         日活   外部   调用次数');
const dauRows = all(
  `SELECT DATE(created_at, '+8 hours') d,
          COUNT(DISTINCT device_id) dev,
          ${extDevExpr} ext,
          COUNT(*) calls
   FROM ai_call_logs
   WHERE created_at >= datetime('now', '-30 days')
   GROUP BY d ORDER BY d`,
  internalIds
);
for (const r of dauRows) {
  console.log(`  ${r.d}  ${String(r.dev).padStart(4)}  ${String(r.ext).padStart(6)}  ${String(r.calls).padStart(7)}`);
}

// ── 3. 近30天设备活跃天数分布 ─────────────────────────────
console.log('\n【3】近30天设备活跃天数分布（一台设备来过几天）');
console.log('  活跃天数      全部   外部');
const perDevice = all(
  `SELECT device_id, COUNT(DISTINCT DATE(created_at, '+8 hours')) days
   FROM ai_call_logs
   WHERE created_at >= datetime('now', '-30 days')
   GROUP BY device_id`
);
const bucketOf = (d) => (d <= 1 ? '1天' : d <= 3 ? '2-3天' : d <= 7 ? '4-7天' : d <= 15 ? '8-15天' : '16天以上');
const bucketKeys = ['1天', '2-3天', '4-7天', '8-15天', '16天以上'];
const bucketsAll = Object.fromEntries(bucketKeys.map(k => [k, 0]));
const bucketsExt = Object.fromEntries(bucketKeys.map(k => [k, 0]));
let externalStable = 0;
for (const r of perDevice) {
  bucketsAll[bucketOf(r.days)]++;
  if (!isInternal(r.device_id) && !/^e2e-/.test(r.device_id || '')) {
    bucketsExt[bucketOf(r.days)]++;
    if (r.days >= 4) externalStable++;
  }
}
for (const k of bucketKeys) console.log(`  ${k.padEnd(6)}   ${String(bucketsAll[k]).padStart(4)}  ${String(bucketsExt[k]).padStart(5)}`);
console.log('  ────────────────────');
console.log(`  外部稳定设备（≥4天）   ${String(externalStable).padStart(4)}  ← 核心数：真实外部用户盘子`);

// ── 4. 近30天新设备进场 ───────────────────────────────────
console.log('\n【4】近30天新设备进场（按首次出现日，北京时间）');
const newcomers = all(
  `SELECT DATE(fs, '+8 hours') d, COUNT(*) n FROM
     (SELECT device_id, MIN(created_at) fs FROM ai_call_logs GROUP BY device_id)
   WHERE DATE(fs, '+8 hours') >= DATE(datetime('now', '-30 days'), '+8 hours')
   GROUP BY d ORDER BY d`
);
for (const r of newcomers) console.log(`  ${r.d}   新设备 ${String(r.n).padStart(3)} 台`);

// ── 5. 稳定设备 TOP12 ─────────────────────────────────────
console.log('\n【5】近30天最稳定设备 TOP12（设备号已脱敏）');
console.log('  设备       活跃天数  调用数   最后活跃(北京)   备注');
const top = all(
  `SELECT device_id,
          COUNT(DISTINCT DATE(created_at, '+8 hours')) days,
          COUNT(*) calls,
          datetime(MAX(created_at), '+8 hours') last
   FROM ai_call_logs
   WHERE created_at >= datetime('now', '-30 days')
   GROUP BY device_id
   ORDER BY days DESC, calls DESC
   LIMIT 12`
);
for (const r of top) {
  const note = isInternal(r.device_id) ? '内部白名单' : '';
  console.log(`  ${mask(r.device_id)}   ${String(r.days).padStart(4)}   ${String(r.calls).padStart(6)}   ${r.last}   ${note}`);
}

// ── 6. 真实付费订阅 ───────────────────────────────────────
console.log('\n【6】真实付费订阅（Production 环境、未退款、未过期）');
const subs = all(`SELECT device_id, tier, product_id, environment, expires_at, revoked_at, updated_at
                  FROM subscription_entitlements ORDER BY updated_at DESC`);
const nowIso = new Date().toISOString();
const paying = subs.filter(s => s.environment === 'Production' && !s.revoked_at && s.expires_at && s.expires_at > nowIso);
const prodHist = subs.filter(s => s.environment === 'Production').length;
console.log(`  当前有效付费：${paying.length} 笔（Production 历史记录 ${prodHist} 笔）`);
for (const s of paying) {
  console.log(`  ${mask(s.device_id)}  ${s.tier}  ${s.product_id.replace('com.tangyuxuan.holo.', '')}  到期 ${s.expires_at.slice(0, 10)}`);
}

// ── 7. App 版本 / 系统分布（request_logs，9/24 起才有数据）──
console.log('\n【7】App 版本分布（近30天请求日志）');
console.log('  说明：build 号 30=1.0.8、31=1.0.9；Darwin 25=iOS26 系、24=iOS18 系');
const uaPairs = all(
  `SELECT DISTINCT user_agent, device_id FROM request_logs
   WHERE user_agent LIKE 'Holo/%' AND created_at >= datetime('now', '-30 days')`
);
const devByBuild = {};
const devByDarwin = {};
for (const r of uaPairs) {
  const build = (r.user_agent.match(/^Holo\/(\d+)/) || [])[1] || '?';
  const darwin = (r.user_agent.match(/Darwin\/(\d+)/) || [])[1] || '?';
  (devByBuild[build] = devByBuild[build] || new Set()).add(r.device_id);
  (devByDarwin[darwin] = devByDarwin[darwin] || new Set()).add(r.device_id);
}
for (const [build, set] of Object.entries(devByBuild).sort((a, b) => Number(b[0]) - Number(a[0]))) {
  console.log(`  build ${build}   ${String(set.size).padStart(3)} 台`);
}
console.log('  系统代际（Darwin 大版本，同一设备可能跨代出现过，按见过算）:');
for (const [darwin, set] of Object.entries(devByDarwin).sort((a, b) => Number(b[0]) - Number(a[0]))) {
  console.log(`  Darwin ${darwin}   ${String(set.size).padStart(3)} 台`);
}

console.log('\n（完）设备号=安装实例，人数 ≈ 外部稳定设备数 ÷ 1~1.5');

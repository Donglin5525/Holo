// 第二轮审查（2026-11-10）生产库只读核查合集：①token分布/截断 ②顶格输出 ③重发包后续 ④账本双源对账 ⑤真实用户 ⑥重复付费拆分
// 用法：ssh root@123.56.104.9 'docker exec -i holo-backend node -' < prod_r2_checks.js
const db = require("better-sqlite3")("/data/holo-backend.db", { readonly: true });

// ===== tokens =====
{
// 第二轮核查①：各环节 token 分布（截断风险/单次规模），只读元数据
const DEV = 'F50B4915-3411-472A-9C13-E1D5E85FEDB4';
const pct = (a, p) => a.length ? a[Math.min(a.length - 1, Math.floor(p * a.length))] : null;
function dist(label, from, to, purpose, dev) {
  const rows = db.prepare(`select prompt_tokens pt, completion_tokens cp, coalesce(cached_tokens,0) ct from ai_call_logs
    where created_at>=? and created_at<? and purpose=? and coalesce(prompt_tokens,0)>0 ${dev ? 'and device_id=?' : ''}`).all(...[from, to, purpose, ...(dev ? [dev] : [])]);
  const pts = rows.map(r => r.pt).sort((a, b) => a - b), cps = rows.map(r => r.cp).sort((a, b) => a - b);
  console.log(`${label} ${purpose} n=${rows.length} 输入 p10/p50/p90/max=${pct(pts,.1)}/${pct(pts,.5)}/${pct(pts,.9)}/${pts.at(-1)} 输出 p50/p90/p99/max=${pct(cps,.5)}/${pct(cps,.9)}/${pct(cps,.99)}/${cps.at(-1)} 输出≥3500的次数=${cps.filter(x => x >= 3500).length}`);
}
for (const p of ['personal_context_extraction', 'personal_context_verification', 'thought_semantic_relate_v1', 'memory_domain_extraction'])
  dist('东林11月', '2026-10-31 16:00:00', '2026-11-10', p, DEV);
dist('东林10月', '2026-10-01', '2026-10-31 16:00:00', 'personal_context_extraction', DEV);
dist('全设备10-15起', '2026-10-15', '2026-11-10', 'personal_context_extraction', null);
// 萃取输入 token 直方图（东林11月，500 一档）：看小包与满包两个峰
const h = {};
for (const r of db.prepare(`select prompt_tokens pt from ai_call_logs where device_id=? and created_at>='2026-10-31 16:00:00' and purpose='personal_context_extraction' and coalesce(prompt_tokens,0)>0`).all(DEV)) { const b = Math.floor(r.pt / 500) * 500; h[b] = (h[b] || 0) + 1; }
console.log('萃取输入直方图', JSON.stringify(h));
console.log('截断类错误（全时段）', JSON.stringify(db.prepare(`select purpose, count(*) n from ai_call_logs where error_message like '%TRUNCAT%' or error_message like '%length%' group by purpose`).all()));
}

// ===== trunc =====
{
// 第二轮核查②：萃取输出顶到 4000 上限的调用——是否同一包反复重试（「毒包」循环）
const rows = db.prepare(`select substr(device_id,1,8) d, created_at t, prompt_tokens pt, completion_tokens cp from ai_call_logs
  where purpose='personal_context_extraction' and completion_tokens >= 3990 and created_at >= '2026-10-01' order by d, pt, t`).all();
console.log('顶格(≥3990)调用数', rows.length);
const groups = {};
for (const r of rows) { const k = `${r.d}|${r.pt}`; (groups[k] ||= []).push(r.t.slice(5, 16)); }
for (const [k, ts] of Object.entries(groups)) console.log(k, '次数', ts.length, ts.join(' , '));
// 同设备、同输入 token 数（±0）的萃取调用重复次数分布：判断失败包是否被整包重发
const rep = db.prepare(`select substr(device_id,1,8) d, prompt_tokens pt, count(*) n, min(created_at) f, max(created_at) l, max(completion_tokens) mx
  from ai_call_logs where purpose='personal_context_extraction' and coalesce(prompt_tokens,0)>0 and created_at >= '2026-10-31 16:00:00'
  group by device_id, prompt_tokens having n >= 2 order by n desc limit 12`).all();
console.log('\n11月 同设备同输入token数重复≥2次的萃取（疑似同一包重发）');
for (const r of rep) console.log(r.d, 'pt', r.pt, '次数', r.n, r.f.slice(5, 16), '→', r.l.slice(5, 16), '最大输出', r.mx);
const tot = db.prepare(`select count(*) n, sum(n) s from (select count(*) n from ai_call_logs where purpose='personal_context_extraction' and coalesce(prompt_tokens,0)>0 and created_at >= '2026-10-31 16:00:00' and device_id like 'F50B4915%' group by prompt_tokens having n>=2)`).get();
console.log('东林11月：重复输入组数', tot.n, '涉及调用', tot.s);
}

// ===== ledger =====
{
// 第二轮核查④：双来源对账——调用日志按牌价算 vs 预算账本实扣（同一窗口：北京时间 11-01~11-09，全部设备）
const cost = r => ((r.pt - r.ct) * 0.2 + r.ct * 0.04 + r.cp * 0.8) / 1e6;
const L = {};
for (const r of db.prepare(`select purpose, count(*) n, sum(charged_micro) ch, sum(reserved_micro) rs,
    sum(case when charged_micro is null then 1 else 0 end) unsettled from background_cost_calls where day between '2026-11-01' and '2026-11-09' group by purpose`).all()) L[r.purpose] = r;
const A = {};
for (const r of db.prepare(`select purpose, sum(case when coalesce(prompt_tokens,0)>0 then 1 else 0 end) billed,
    sum(coalesce(prompt_tokens,0)) pt, sum(coalesce(completion_tokens,0)) cp, sum(coalesce(cached_tokens,0)) ct
    from ai_call_logs where created_at >= '2026-10-31 16:00:00' and created_at < '2026-11-09 16:00:00' group by purpose`).all()) A[r.purpose] = r;
console.log('purpose | 日志计费次数 | 日志按牌价¥ | 账本条数 | 账本实扣¥ | 账本预留¥ | 未结算条数 | 实扣/牌价');
for (const p of Object.keys(L).sort()) {
  const a = A[p] || { billed: 0, pt: 0, cp: 0, ct: 0 }; const l = L[p];
  const c = cost(a); const ch = (l.ch || 0) / 1e6;
  console.log([p, a.billed, c.toFixed(4), l.n, ch.toFixed(4), (l.rs / 1e6).toFixed(4), l.unsettled, c ? (ch / c).toFixed(3) : '-'].join(' | '));
}
}

// ===== realusers =====
{
// 第二轮核查⑤：真实用户（非调试设备）后台花费——最重用户近况 + 全体按环节
const cost = r => ((r.pt - r.ct) * 0.2 + r.ct * 0.04 + r.cp * 0.8) / 1e6;
const debug = new Set(db.prepare(`select distinct device_id from product_events where build_channel='debug'`).all().map(r => r.device_id));
const BG = ['personal_context_extraction','personal_context_verification','thought_semantic_relate_v1','memory_domain_extraction','discovery_candidate_v1','discovery_verify_v1','discovery_topic_v1','thought_topic_name_v1','thought_category_brief_v1','thought_topic_summary_v1','replayDigest','cloud_replay_digest'];
const q = (from, to) => db.prepare(`select device_id d, purpose p, sum(case when coalesce(prompt_tokens,0)>0 then 1 else 0 end) billed, sum(coalesce(prompt_tokens,0)) pt, sum(coalesce(completion_tokens,0)) cp, sum(coalesce(cached_tokens,0)) ct
  from ai_call_logs where created_at >= ? and created_at < ? and purpose in (${BG.map(() => '?').join(',')}) group by d, p`).all(from, to, ...BG);
// BCA59F42：10-30 起（北京时间）11 天
const bca = q('2026-10-29 16:00:00', '2026-11-09 16:00:00').filter(r => r.d.startsWith('BCA59F42'));
let t = 0; for (const r of bca) { t += cost(r); console.log('BCA59F42', r.p, '计费', r.billed, '¥' + cost(r).toFixed(4), '单次¥' + (cost(r) / Math.max(1, r.billed)).toFixed(5)); }
console.log('BCA59F42 10-30~11-09 共11天 ¥' + t.toFixed(3), '→ 折月 ¥' + (t / 11 * 30).toFixed(2));
// 全体真实设备：11 月前 9 天，按环节
const rows = q('2026-10-31 16:00:00', '2026-11-09 16:00:00').filter(r => !debug.has(r.d) && !/^(zcode|pc-eval|probe)/.test(r.d));
const by = {}; const devs = new Set();
for (const r of rows) { devs.add(r.d); (by[r.p] ||= { billed: 0, c: 0 }); by[r.p].billed += r.billed; by[r.p].c += cost(r); }
console.log('\n真实设备 11-01~11-09：有后台调用的设备', devs.size);
for (const [p, v] of Object.entries(by).sort((a, b) => b[1].c - a[1].c)) console.log(' ', p, '计费', v.billed, '¥' + v.c.toFixed(4));
}

// ===== dup =====
{
// 第二轮核查⑥：重复发包拆成两类——同一分钟内（并发双跑）vs 隔了很久（失败后重付）——各花多少钱
const DEV = 'F50B4915-3411-472A-9C13-E1D5E85FEDB4';
const ts = s => Date.parse(s.replace(' ', 'T') + 'Z');
const price = c => ((c.pt - c.ct) * 0.2 + c.ct * 0.04 + c.cp * 0.8) / 1e6;
for (const purpose of ['personal_context_extraction', 'personal_context_verification', 'memory_domain_extraction', 'thought_semantic_relate_v1']) {
  const X = db.prepare(`select created_at t, prompt_tokens pt, coalesce(completion_tokens,0) cp, coalesce(cached_tokens,0) ct from ai_call_logs
     where device_id=? and purpose=? and coalesce(prompt_tokens,0)>0 and created_at>='2026-10-31 16:00:00' order by created_at`).all(DEV, purpose);
  const lastT = {}; let total = 0, conc = 0, concN = 0, later = 0, laterN = 0;
  for (const c of X) {
    total += price(c);
    const prev = lastT[c.pt];
    if (prev !== undefined) {
      if (ts(c.t) - prev < 3 * 60e3) { conc += price(c); concN++; } else { later += price(c); laterN++; }
    }
    lastT[c.pt] = ts(c.t);
  }
  console.log(`${purpose}: 总 ¥${total.toFixed(3)}（${X.length}次）| 3分钟内重复 ${concN}次 ¥${conc.toFixed(3)}（${(100*conc/total).toFixed(0)}%）| 隔3分钟以上重复 ${laterN}次 ¥${later.toFixed(3)}（${(100*later/total).toFixed(0)}%）`);
}
// 同一分钟内的重复：两次调用是否时间上重叠（第二次开始时第一次还没结束 → 并发铁证）
const rows = db.prepare(`select created_at t, prompt_tokens pt, duration_ms d from ai_call_logs where device_id=? and purpose='personal_context_extraction' and coalesce(prompt_tokens,0)>0 and created_at>='2026-10-31 16:00:00' order by created_at`).all(DEV);
const firstSeen = {}; let overlap = 0, seq = 0;
for (const r of rows) {
  const f = firstSeen[r.pt];
  if (f && ts(r.t) - f.t < 3 * 60e3) { (ts(r.t) < f.t + (f.d || 0)) ? overlap++ : seq++; }
  if (!f || ts(r.t) - f.t >= 3 * 60e3) firstSeen[r.pt] = { t: ts(r.t), d: r.d };
}
console.log('3分钟内的萃取重复：与前一次时间重叠（并发）', overlap, '次；前一次结束后才发（串行重发）', seq, '次');
}

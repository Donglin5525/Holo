// 生产库只读查询（元数据，不读正文）：表结构 + 东林真机 11 月后台调用成本拆分 + 日分布 + 前台轮次聚类。
// 用法：ssh root@123.56.104.9 'docker exec -i holo-backend node -' < prod_donglin_nov.js
// 口径：qwen3.7-flash 牌价 输入 0.2 / 缓存 0.04 / 输出 0.8 元每百万；北京时间 11-01 00:00 = UTC 10-31 16:00。
const db = require('better-sqlite3')('/data/holo-backend.db', { readonly: true });
const DEV = 'F50B4915-3411-472A-9C13-E1D5E85FEDB4';
const FROM = '2026-10-31 16:00:00';
const cost = r => ((r.pt - r.ct) * 0.2 + r.ct * 0.04 + r.cp * 0.8) / 1e6;

// 1) 账本是否已有 pool 列（判断开发设备池是否已发版）
const bccCols = db.prepare('pragma table_info(background_cost_calls)').all().map(c => c.name);
console.log('background_cost_calls 列：', bccCols.join(','), '| 有 pool 列：', bccCols.includes('pool'));

// 2) 按 purpose 拆分（成功/失败但计费/平均输入输出/缓存命中/思考占比/花费）
const rows = db.prepare(`
 select purpose, count(*) n,
  sum(case when (error_message is null or error_message='') then 1 else 0 end) ok,
  sum(case when (error_message is not null and error_message!='') and coalesce(prompt_tokens,0)>0 then 1 else 0 end) failBilled,
  sum(coalesce(prompt_tokens,0)) pt, sum(coalesce(completion_tokens,0)) cp, sum(coalesce(cached_tokens,0)) ct, sum(coalesce(reasoning_tokens,0)) rt
 from ai_call_logs where device_id=? and created_at>=? group by purpose order by pt desc`).all(DEV, FROM);
console.log('\npurpose | 调用 | 成功 | 失败仍计费 | 均输入 | 均输出 | 缓存% | 思考% | 花费');
let total = 0;
for (const r of rows) {
  const c = cost(r); total += c; const billed = r.ok + r.failBilled;
  console.log([r.purpose, r.n, r.ok, r.failBilled, billed ? Math.round(r.pt / billed) : 0, billed ? Math.round(r.cp / billed) : 0,
    r.pt ? (100 * r.ct / r.pt).toFixed(0) : 0, r.cp ? (100 * r.rt / r.cp).toFixed(0) : 0, c.toFixed(3)].join(' | '));
}
console.log('合计（含聊天/深度分析等非后台项）', total.toFixed(3));

// 3) 错误码前缀（不打印正文）
console.log('\n错误码前缀：');
for (const e of db.prepare(`select purpose, substr(error_message,1,42) e, count(*) n, sum(coalesce(prompt_tokens,0)) pt from ai_call_logs where device_id=? and created_at>=? and error_message is not null and error_message!='' group by purpose, e order by n desc limit 20`).all(DEV, FROM))
  console.log(e.purpose, '|', e.e, '|', e.n, '| 计费输入token', e.pt);

// 4) 前台轮次聚类：萃取+核验调用间隔 >10 分钟视为新一轮
const calls = db.prepare(`select created_at, purpose from ai_call_logs where device_id=? and created_at>=? and purpose in ('personal_context_extraction','personal_context_verification') and coalesce(prompt_tokens,0)>0 order by created_at`).all(DEV, FROM);
const ts = s => Date.parse(s.replace(' ', 'T') + 'Z');
const passes = []; let cur = null;
for (const c of calls) { const t = ts(c.created_at); if (!cur || t - cur.last > 600e3) { cur = { last: t, x: 0, v: 0 }; passes.push(cur); } cur.last = t; c.purpose === 'personal_context_extraction' ? cur.x++ : cur.v++; }
const hist = {}; for (const p of passes) hist[p.x] = (hist[p.x] || 0) + 1;
console.log('\n轮次数', passes.length, '每轮萃取次数分布', JSON.stringify(hist));

// 5) 萃取单次输入 token 中位数（按天，看 10 月→11 月变化）
const med = a => { a.sort((x, y) => x - y); return a.length ? a[Math.floor(a.length / 2)] : 0; };
const g = {};
for (const r of db.prepare(`select date(created_at,'+8 hours') d, prompt_tokens pt from ai_call_logs where device_id=? and purpose='personal_context_extraction' and created_at>='2026-10-08' and coalesce(prompt_tokens,0)>0`).all(DEV)) (g[r.d] ||= []).push(r.pt);
console.log('萃取输入 token 中位数（日:中位数(次数)）', Object.entries(g).map(([d, a]) => `${d.slice(5)}:${med(a)}(${a.length})`).join(' '));

// 生产库只读查询（元数据）：设备分类（debug/release/无埋点）+ 真实用户后台成本 + 想法关联日分布 + 谁在跑个人档案萃取。
// 用法：ssh root@123.56.104.9 'docker exec -i holo-backend node -' < prod_fleet.js
const db = require('better-sqlite3')('/data/holo-backend.db', { readonly: true });
const cost = r => ((r.pt - r.ct) * 0.2 + r.ct * 0.04 + r.cp * 0.8) / 1e6;
const BG = ['personal_context_extraction', 'personal_context_verification', 'thought_semantic_relate_v1', 'memory_domain_extraction',
  'discovery_candidate_v1', 'discovery_verify_v1', 'thought_topic_name_v1', 'thought_category_brief_v1', 'thought_topic_summary_v1', 'replayDigest', 'cloud_replay_digest'];

const debugDevs = new Set(db.prepare(`select distinct device_id from product_events where build_channel='debug'`).all().map(r => r.device_id));
const relDevs = new Set(db.prepare(`select distinct device_id from product_events where build_channel='release'`).all().map(r => r.device_id));
console.log('debug 设备', debugDevs.size, 'release 设备', relDevs.size, '重叠', [...debugDevs].filter(d => relDevs.has(d)).length);

// 1) 10-15 以来后台成本按设备类别
const rows = db.prepare(`select device_id d, sum(coalesce(prompt_tokens,0)) pt, sum(coalesce(completion_tokens,0)) cp, sum(coalesce(cached_tokens,0)) ct
  from ai_call_logs where created_at >= '2026-10-15' and purpose in (${BG.map(() => '?').join(',')}) group by d`).all(...BG);
const cls = {};
for (const r of rows) { const k = debugDevs.has(r.d) ? 'debug' : relDevs.has(r.d) ? 'release' : '无埋点'; (cls[k] ||= { n: 0, cost: 0, max: 0 }); const c = cost(r); cls[k].n++; cls[k].cost += c; cls[k].max = Math.max(cls[k].max, c); }
console.log('10-15 以来后台成本（26 天）', JSON.stringify(Object.fromEntries(Object.entries(cls).map(([k, v]) => [k, { 设备: v.n, 合计: +v.cost.toFixed(3), 单台最高: +v.max.toFixed(3) }]))));

// 2) 谁在跑个人档案萃取（应全部是 debug 设备）
for (const r of db.prepare(`select device_id d, count(*) n from ai_call_logs where purpose='personal_context_extraction' and created_at>='2026-10-09' group by d order by n desc`).all())
  console.log('个人档案萃取设备', r.d.slice(0, 8), r.n, debugDevs.has(r.d) ? 'debug' : relDevs.has(r.d) ? 'release' : '无埋点');

// 3) 想法关联/主题命名/类别说明 日分布（计费次数/总次数）：东林真机 + 最重真实用户
for (const pre of ['F50B4915', 'BCA59F42']) {
  console.log(`\n${pre} 日分布 relate / topic-name / brief（计费/总）`);
  for (const r of db.prepare(`select date(created_at,'+8 hours') d,
      sum(case when purpose='thought_semantic_relate_v1' and coalesce(prompt_tokens,0)>0 then 1 else 0 end) rb, sum(case when purpose='thought_semantic_relate_v1' then 1 else 0 end) ra,
      sum(case when purpose='thought_topic_name_v1' and coalesce(prompt_tokens,0)>0 then 1 else 0 end) nb,
      sum(case when purpose='thought_category_brief_v1' and coalesce(prompt_tokens,0)>0 then 1 else 0 end) bb, sum(case when purpose='thought_category_brief_v1' then 1 else 0 end) ba
    from ai_call_logs where device_id like ? and created_at>='2026-10-08' group by d having ra+nb+ba>0 order by d`).all(pre + '%'))
    console.log(`${r.d.slice(5)} relate=${r.rb}/${r.ra} name=${r.nb} brief=${r.bb}/${r.ba}`);
}

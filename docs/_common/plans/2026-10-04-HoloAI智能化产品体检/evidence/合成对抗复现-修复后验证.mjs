// 2026-10-04 体检 AI02 修复后的翻转验证：与「合成对抗复现入口.mjs」同一构造，
// 但每个坏场景给足两轮相同坏输出（修复轮后再编），证明终态是核验拦截后的
// 诚实 failed，而不是 provider 耗尽造成的假 failed；另加正向冒烟证明正常
// 事实（金额与工具结果一致）不被收紧误杀。期望全部满足则退出码 0。
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { createDatabase } from '/Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/src/db/database.js';
import { createCloudAnalysisTaskStore } from '/Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/src/agent/cloudAnalysisTaskStore.js';
import { createCloudAnalysisExecutor } from '/Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/src/agent/cloudAnalysisExecutor.js';

const json = (status, extra = {}) => JSON.stringify({ status, reasoning: '合成体检', toolRequests: [], claims: [], warnings: [], ...extra });
const snapshot = { version: 1, generatedAt: '2026-10-04T00:00:00Z', historyDays: 180, datasets: { 'finance.transactions': { fields: [{name:'date',type:'date'},{name:'amount',type:'number',unit:'元'},{name:'category',type:'text'}], rows: [{id:'a',date:'2026-10-01',amount:-32,category:'餐饮'},{id:'b',date:'2026-10-02',amount:-42,category:'交通'}] } } };
const query = json('need_tools', {toolRequests: [{ id:'t1', tool:'finance', query:'dynamic_query', parameters:{ dynamicPlan:{ source:'finance.transactions', filters:[], groupBy:[], aggregations:[{id:'total',operation:'sum',field:'amount',unit:'元'}], derivations:[] } } }]});
const claim = (displayText, evidenceIDs = [], metricAssertions = []) => ({id:'c1',type:'observation',summary:displayText,displayText,evidenceIDs,metricAssertions});
async function probe(label, data, responses) {
  const database = createDatabase({dbPath:':memory:'});
  const store = createCloudAnalysisTaskStore(database.db,{encryptionKey:randomBytes(32).toString('base64')});
  const calls = [];
  const provider = { async complete(req) { calls.push(req); const content = responses.shift(); if (!content) throw Error('PROVIDER_EXHAUSTED'); return {choices:[{index:0,message:{role:'assistant',content},finish_reason:'stop'}],usage:{prompt_tokens:0,completion_tokens:0}}; } };
  const executor = createCloudAnalysisExecutor({taskStore:store,providers:new Map([['fake',provider]]),route:{provider:'fake',model:'synthetic',maxTokens:1024},providerRetries:1,log:()=>{},injectedQuestionTimeResolver:{resolveQuestionTime:async()=>null}});
  const task = store.create({deviceId:'isolated-audit',question:'最近的支出情况如何？'});
  store.attachSnapshot({id:task.id,snapshot:JSON.stringify(data)});
  const status = await executor.run(task.id);
  const raw = store.getDecrypted(task.id,['result','failureReason']);
  const result = raw?.result ? JSON.parse(raw.result) : null;
  database.db.close();
  return { label, status, providerCalls: calls.length, claims: result?.claims ?? [], warnings: result?.warnings ?? [], failureReason: raw?.failureReason ?? null };
}
const empty = {...snapshot, datasets: {}};
const rows = [];
// R01：空数据定性事实（修复前 completed + NO_TOOL_EVIDENCE 警告照常交付）
const r01bad = json('final_claims',{claims:[claim('支出以餐饮外卖为主')]});
rows.push(await probe('R01 空数据定性事实（期望 failed）', empty, [r01bad, r01bad]));
// R02：合法引用但正文编数（修复前 completed，错误金额 9999 交付）
const r02bad = json('final_claims',{claims:[claim('最近总支出 9999 元',['dynamic.finance_transactions.total.all'])]});
rows.push(await probe('R02 合法引用但正文编数（期望 failed）', snapshot, [query, r02bad, r02bad]));
// R03：数字断言对账失败但引用存在（修复前 completed，断言剥离正文保留）
const r03bad = json('final_claims',{claims:[claim('最近总支出 9999 元',['dynamic.finance_transactions.total.all'],[{metricKey:'dynamic.finance_transactions.total.all',value:-9999,unit:'元',evidenceIDs:[]}])]});
rows.push(await probe('R03 对账失败但引用存在（期望 failed）', snapshot, [query, r03bad, r03bad]));
// R04：空数据无引用数字（S02 已修，保持 failed）
const r04bad = json('final_claims',{claims:[claim('最近总支出 99999 元')]});
rows.push(await probe('R04 空数据无引用数字（期望 failed，S02 保持）', empty, [r04bad, r04bad]));
// 正向冒烟：金额与工具结果一致（真实 -74）→ 不误杀，completed
rows.push(await probe('正向冒烟：金额一致（期望 completed 不误杀）', snapshot, [query, json('final_claims',{claims:[claim('最近总支出 74 元',['dynamic.finance_transactions.total.all'],[{metricKey:'dynamic.finance_transactions.total.all',value:-74,unit:'元',evidenceIDs:[]}])]})]));

assert.equal(rows[0].status, 'failed', 'R01 空数据定性事实须诚实失败');
assert.equal(rows[0].providerCalls, 2, 'R01 原始+修复轮各一次');
assert.ok((rows[0].failureReason ?? '').includes('可核验'), 'R01 失败原因可解释');
assert.equal(rows[1].status, 'failed', 'R02 合法引用护不住编造金额');
assert.equal(rows[1].providerCalls, 3, 'R02 工具+原始+修复轮');
assert.ok((rows[1].failureReason ?? '').includes('可核验'), 'R02 失败原因可解释');
assert.equal(rows[2].status, 'failed', 'R03 对账失败不得保留错误正文');
assert.equal(rows[2].providerCalls, 3, 'R03 工具+原始+修复轮');
assert.ok((rows[2].failureReason ?? '').includes('可核验'), 'R03 失败原因可解释');
assert.equal(rows[3].status, 'failed', 'R04 S02 修复保持');
assert.equal(rows[4].status, 'completed', '正常事实不得误杀');
assert.equal(rows[4].claims.length, 1, '正向冒烟 claim 正常交付');
assert.equal(rows[4].claims[0].metricAssertions.length, 1, '对账一致的断言保留');

console.log(JSON.stringify(rows.map(({label,status,providerCalls,claims,failureReason})=>({label,status,providerCalls,claims:claims.length,failureReason})), null, 2));
console.log('全部期望满足：R01/R02/R03 翻转为诚实 failed，R04 保持，正向冒烟不误杀。');

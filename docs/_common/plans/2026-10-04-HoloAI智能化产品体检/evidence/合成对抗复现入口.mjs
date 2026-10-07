import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { writeFileSync } from 'node:fs';
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
  const provider = { async complete() { const content = responses.shift(); if (!content) throw Error('PROVIDER_EXHAUSTED'); return {choices:[{index:0,message:{role:'assistant',content},finish_reason:'stop'}],usage:{prompt_tokens:0,completion_tokens:0}}; } };
  const executor = createCloudAnalysisExecutor({taskStore:store,providers:new Map([['fake',provider]]),route:{provider:'fake',model:'synthetic',maxTokens:1024},providerRetries:1,log:()=>{},injectedQuestionTimeResolver:{resolveQuestionTime:async()=>null}});
  const task = store.create({deviceId:'isolated-audit',question:'最近的支出情况如何？'});
  store.attachSnapshot({id:task.id,snapshot:JSON.stringify(data)});
  const status = await executor.run(task.id);
  const raw = store.getDecrypted(task.id,['result','failureReason']);
  const result = raw?.result ? JSON.parse(raw.result) : null;
  const out = {label,status,claims:result?.claims??[],warnings:result?.warnings??[],evidence:result?.evidence??[],failureReason:raw?.failureReason??null};
  database.db.close();
  return out;
}
const empty = {...snapshot,datasets:{}};
const rows = [];
rows.push(await probe('空数据定性事实',empty,[json('final_claims',{claims:[claim('支出以餐饮外卖为主')]})]));
rows.push(await probe('合法引用但正文编数',snapshot,[query,json('final_claims',{claims:[claim('最近总支出 9999 元',['dynamic.finance_transactions.total.all'])]})]));
rows.push(await probe('对账失败但引用存在',snapshot,[query,json('final_claims',{claims:[claim('最近总支出 9999 元',['dynamic.finance_transactions.total.all'],[{metricKey:'dynamic.finance_transactions.total.all',value:-9999,unit:'元',evidenceIDs:[]}])]})]));
const bad = json('final_claims',{claims:[claim('最近总支出 99999 元')]});
rows.push(await probe('空数据无引用数字已拦截',empty,[bad,bad]));
assert.equal(rows[0].status,'completed');
assert.equal(rows[1].status,'completed');
assert.equal(rows[2].status,'completed');
assert.equal(rows[3].status,'failed');
writeFileSync('/tmp/holoai-intelligence-probe-20261004.json',JSON.stringify(rows,null,2));
console.log(JSON.stringify(rows.map(({label,status,claims,warnings})=>({label,status,claims,warnings})),null,2));

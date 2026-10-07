import { randomBytes } from 'node:crypto';
import { createDatabase } from '/Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/src/db/database.js';
import { createCloudAnalysisTaskStore } from '/Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/src/agent/cloudAnalysisTaskStore.js';
import { createCloudAnalysisExecutor } from '/Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/src/agent/cloudAnalysisExecutor.js';
import { createApp } from '/Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/src/app.js';

const database = createDatabase({ dbPath: ':memory:' });
const key = randomBytes(32).toString('base64');
const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: key });
let calls = 0;
const provider = { async complete() {
  calls += 1;
  return { choices: [{ message: { role: 'assistant', content: JSON.stringify({
    status: 'final_claims', reasoning: 'synthetic', toolRequests: [], warnings: [],
    claims: [{id:'c1',type:'observation',summary:'本月支出 99999 元',displayText:'本月支出 99999 元',evidenceIDs:[],metricAssertions:[]}]
  }) }, finish_reason: 'stop' }], usage: {prompt_tokens:1, completion_tokens:1} };
} };
const executor = createCloudAnalysisExecutor({taskStore:store,providers:new Map([['fake',provider]]),route:{provider:'fake',model:'m',maxTokens:1024},providerRetries:1,log:()=>{},injectedQuestionTimeResolver:{resolveQuestionTime:async()=>null}});
const task = store.create({ deviceId:'audit-synthetic',question:'我的支出情况',taskType:'deep_analysis' });
store.attachSnapshot({id:task.id,snapshot:JSON.stringify({version:1,generatedAt:'2026-10-04T00:00:00Z',historyDays:180,datasets:{}})});
const status = await executor.run(task.id);
const rawResult = store.getDecrypted(task.id,['result']).result;
console.log('AUDIT_CLOUD',JSON.stringify({status,calls,result:rawResult?JSON.parse(rawResult):null}));

const app = createApp({database,auth:{enforceAppAttest:true},runtimeEnvironment:'test',aiCallLogs:{enabled:false},cloudAnalysisEncryptionKey:key,cloudAnalysisTaskStore:store,cloudAnalysisExecutor:{run:async()=> 'queued'}});
const response = await app.request('/v1/ai/agent/cloud/start',{method:'POST',headers:{'content-type':'application/json','x-holo-device-id':'audit-forged-id'},body:JSON.stringify({question:'synthetic audit question'})});
console.log('AUDIT_IDENTITY',JSON.stringify({enforceAppAttest:true,withAssertion:false,withSession:false,httpStatus:response.status,body:await response.json()}));
database.db.close();

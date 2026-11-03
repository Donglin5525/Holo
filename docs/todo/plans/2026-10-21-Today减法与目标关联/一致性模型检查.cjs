const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = process.argv[2] || '/Users/tangyuxuan/.codex/visualizations/2026/10/20/01a15a2d-886d-7f40-8325-d706a0af90d9/holo-today-goals-integrated.html';
const text = fs.readFileSync(source, 'utf8');
const model = text.split('/* MODEL_BEGIN */')[1].split('/* MODEL_END */')[0];
const context = vm.createContext({ structuredClone });
vm.runInContext(model + ';globalThis.testDomain=Domain;', context);
const D = context.testDomain;
let cases = 0, serial = 0;
const test = (name, run) => { run(); cases++; process.stdout.write(`PASS ${name}\n`); };
const apply = (s, command, options) => D.commit(s, { op: `test-${++serial}`, ...command }, options).store;
const record = (s, h, v, day='2026-10-21') => apply(s, {type:'record',h,v,day,note:''});

test('来源基线与周期一致', () => {
 const s=D.seedStore();assert.equal(D.stats(s,'reviews').sum,2);assert.equal(D.stats(s,'tea').sum,1);assert.equal(D.stats(s,'reading').sum,110);assert.equal(D.balance(s),600000);assert.equal(D.spending(s),160000);
});
test('改一段阅读，不覆盖总数或新增记录', () => {
 const s=D.seedStore(),n=apply(s,{type:'record',id:'r9',h:'reading',day:'2026-10-20',v:65,note:'更正'});
 assert.equal(D.stats(n,'reading').sum,125);assert.equal(n.records.length,s.records.length);assert.equal(n.records.find(r=>r.id==='r9').v,65);assert.equal(D.stats(s,'reading').sum,110);
});
test('删除一段记录后从来源重算', () => { const n=apply(D.seedStore(),{type:'deleteRecord',id:'r9'});assert.equal(D.stats(n,'reading').sum,60); });
test('一条活动同时更新次数与里程', () => {
 const s=D.seedStore(),n=record(s,'run',5);assert.equal(D.ruleValues(n,'routine').run,3);assert.equal(D.ruleValues(n,'distance').km,20);assert.equal(n.records.length,s.records.length+1);
});
test('同ID事实不重复计数', () => { const s=D.seedStore();s.records.push(structuredClone(s.records.find(r=>r.id==='r6')));assert.equal(D.stats(s,'run').count,2);assert.equal(D.stats(s,'run').sum,15); });
test('本目标要求与另一个目标、实际记录分开', () => {
 const s=D.seedStore(),n=apply(s,{type:'plan',goal:'routine',key:'runs',value:2,baseVersion:1,confirmed:true});assert.equal(D.stats(n,'run').count,2);assert.equal(n.plans.routine.runs,2);assert.equal(n.plans.distance.km,40);assert.equal(D.goalMet(n,'routine'),false);
});
test('必要成功条件变更必须明确确认', () => {
 assert.throws(()=>apply(D.seedStore(),{type:'plan',goal:'routine',key:'runs',value:2,baseVersion:1,successChange:false,confirmed:false}),/单独确认/);
});
test('允许零上限，事实数量不变', () => { const n=apply(D.seedStore(),{type:'plan',goal:'travel',key:'tea',value:0,baseVersion:1});assert.equal(n.plans.travel.tea,0);assert.equal(D.stats(n,'tea').sum,1); });
test('未来版本和越界天数不悄悄采用', () => {
 assert.throws(()=>apply(D.seedStore(),{type:'plan',goal:'routine',key:'bed',value:8,baseVersion:1,confirmed:true}),/有效要求/);
 assert.throws(()=>apply(D.seedStore(),{type:'plan',goal:'routine',key:'runs',value:2,baseVersion:9,confirmed:true}),/计划已更新/);
});
test('确认未发生与没有记录不同', () => {
 const s=D.seedStore(),n=apply(s,{type:'confirm',h:'tea',day:'2026-10-20',status:'none'});assert.equal(D.stats(n,'tea').sum,1);assert.equal(D.stats(n,'tea').covered,D.stats(s,'tea').covered+1);assert.equal(D.confirmation(n,'tea','2026-10-20').valid,true);
});
test('今天只确认截至当前，不算全天完整覆盖', () => {
 const s=D.seedStore(),n=apply(s,{type:'confirm',h:'tea',day:'2026-10-21',status:'asof_complete'});assert.equal(D.stats(n,'tea').covered,D.stats(s,'tea').covered);
 assert.throws(()=>apply(s,{type:'confirm',h:'tea',day:'2026-10-21',status:'none'}),/不适用|今天尚未结束/);
});
test('正数与无发生确认不能共存为有效事实', () => {
 const s=D.seedStore();assert.throws(()=>apply(s,{type:'confirm',h:'tea',day:'2026-10-19',status:'none'}),/正数记录/);
 const n=record(s,'tea',1,'2026-10-15');assert.equal(D.confirmation(n,'tea','2026-10-15').valid,false);assert.equal(D.stats(n,'tea').sum,2);
});
test('仅改备注不破坏数量完整性，报告依据仍变化', () => {
 let s=D.seedStore();s=apply(s,{type:'confirm',h:'tea',day:'2026-10-19',status:'complete'});const hash=D.sourceHash(s,'travel');const n=apply(s,{type:'record',id:'r3',h:'tea',day:'2026-10-19',v:1,note:'补充说明'});assert.equal(D.confirmation(n,'tea','2026-10-19').valid,true);assert.notEqual(D.sourceHash(n,'travel'),hash);
});
test('没做到不伪造符合次数，补确认只增加覆盖', () => {
 const s=D.seedStore(),n=apply(s,{type:'confirm',h:'bed',day:'2026-10-19',status:'notmet'});assert.equal(D.stats(n,'bed',D.WINDOWS.nights).met,3);assert.equal(D.stats(n,'bed',D.WINDOWS.nights).covered,6);
});
test('更正符合为没做到、撤回状态都能重算', () => {
 let s=D.seedStore();s=apply(s,{type:'confirm',h:'bed',day:'2026-10-14',status:'notmet'});assert.equal(D.stats(s,'bed',D.WINDOWS.nights).met,2);s=apply(s,{type:'unconfirm',h:'bed',day:'2026-10-14'});assert.equal(D.stats(s,'bed',D.WINDOWS.nights).covered,4);
});
test('真实测量0与没有观测分开', () => { const s=D.seedStore();assert.equal(D.stats(s,'weight').known,false);const n=record(s,'weight',0);assert.equal(D.stats(n,'weight').latest,0);assert.equal(D.stats(n,'weight').known,true);assert.throws(()=>record(s,'tea',0),/本次数量/); });
test('测量取最新一条，不累计', () => { let s=D.seedStore();s=record(s,'weight',60);s=record(s,'weight',61);assert.equal(D.stats(s,'weight').latest,61); });
test('同一操作重试不创建两条', () => { const s=D.seedStore(),c={type:'record',h:'run',day:'2026-10-21',v:5,note:'',op:'same-operation'};const n=D.commit(s,c).store;const repeated=D.commit(n,c);assert.equal(repeated.duplicate,true);assert.equal(D.stats(repeated.store,'run').count,3); });
test('保存失败没有改事实，输入命令可用原操作重试', () => { const s=D.seedStore(),before=JSON.stringify(s),c={type:'record',h:'run',day:'2026-10-21',v:5,note:'保留输入',op:'retryable'};assert.throws(()=>D.commit(s,c,{fail:true}),/输入已保留/);assert.equal(JSON.stringify(s),before);assert.equal(D.stats(D.commit(s,c).store,'run').count,3); });
test('改转账金额同时改变两个账户，不改变消费', () => { const s=D.seedStore(),n=apply(s,{type:'money',id:'m1',cents:150000,note:'更正'});assert.equal(D.balance(n),630000);assert.equal(D.balance(n,'daily'),D.balance(s,'daily')-30000);assert.equal(D.spending(n),160000); });
test('余额核对追加差额，不伪装收入或消费', () => { let s=D.seedStore();s=apply(s,{type:'reconcile',cents:650000,note:''});assert.equal(D.balance(s),650000);assert.equal(s.money.at(-1).cents,50000);assert.equal(D.spending(s),160000);s=apply(s,{type:'reconcile',cents:500000,note:''});assert.equal(D.balance(s),500000); });
test('全局预算单独确认，实际支出不改', () => { const s=D.seedStore();assert.throws(()=>apply(s,{type:'budget',cents:170000,baseVersion:1,confirmed:false}),/全局预算/);const n=apply(s,{type:'budget',cents:170000,baseVersion:1,confirmed:true});assert.equal(D.ruleValues(n,'travel').budget,170000);assert.equal(D.spending(n),160000); });
test('完成验证任务不等于独立提案成功', () => { const s=apply(D.seedStore(),{type:'task',id:'meeting',done:true});assert.equal(D.goalMet(s,'english'),false);const h=apply(s,{type:'feedback',status:'help',note:'还需要帮助'});assert.equal(D.ruleValues(h,'english').attempted,true);assert.equal(D.goalMet(h,'english'),false);const n=apply(h,{type:'feedback',status:'independent',note:'独立讲清'});assert.equal(D.goalMet(n,'english'),true); });
test('刷新保留旧报告；同依据不重复生成', () => { const s=D.seedStore(),old=JSON.stringify(s.reports.travel);let n=apply(s,{type:'report',goal:'travel'});assert.equal(JSON.stringify(n.reportHistory[0]),old);const id=n.reports.travel.id;n=apply(n,{type:'report',goal:'travel'});assert.equal(n.reports.travel.id,id);assert.equal(n.reportHistory.length,1); });
test('改原记录不篡改已保存报告', () => { let s=apply(D.seedStore(),{type:'report',goal:'travel'});const report=JSON.stringify(s.reports.travel);const n=apply(s,{type:'reconcile',cents:720000,note:''});assert.equal(JSON.stringify(n.reports.travel),report);assert.notEqual(n.reports.travel.hash,D.sourceHash(n,'travel')); });
test('本期之外不混入本期统计；不新增未来记录', () => { const s=D.seedStore();s.records.push({id:'outside',h:'run',day:'2026-10-01',v:7,note:''});assert.equal(D.stats(s,'run').count,2);assert.equal(D.stats(s,'run',D.WINDOWS.month).sum,22);assert.throws(()=>record(s,'run',5,'2026-10-22'),/补记/); });
test('金额使用分，拒绝隐含小数误差和多余精度', () => { assert.equal(D.moneyNumber('12.34'),1234);assert.throws(()=>D.moneyNumber('1.234'),/两位小数/); });
test('来源纠正后存钱预演从3300重算为3000，历史建议不变', () => {
 let s=apply(D.seedStore(),{type:'deleteMoney',id:'m1'});s=apply(s,{type:'report',goal:'travel'});assert.equal(s.reports.travel.monthlySuggestion,330000);
 s=apply(s,{type:'reconcile',cents:600000,note:''});s=apply(s,{type:'report',goal:'travel'});assert.equal(s.reports.travel.monthlySuggestion,300000);assert.equal(s.reportHistory.at(-1).monthlySuggestion,330000);
});
test('采用回顾预演前再次验证依据，过期不写计划', () => {
 let s=apply(D.seedStore(),{type:'report',goal:'travel'});const hash=s.reports.travel.hash;s=apply(s,{type:'reconcile',cents:720000,note:''});
 assert.throws(()=>apply(s,{type:'plan',goal:'travel',key:'monthly',value:330000,baseVersion:1,sourceHash:hash}),/依据已变化/);assert.equal(s.plans.travel.monthly,300000);
});
test('上床必须确认真实状态，不能从普通数量表单伪造', () => {assert.throws(()=>record(D.seedStore(),'bed',1),/实际状态/);});
test('已采用的安排保留报告身份，并区分采用与再次过期', () => {
 let s=apply(D.seedStore(),{type:'plan',goal:'travel',key:'monthly',value:330000,baseVersion:1});s=apply(s,{type:'report',goal:'travel'});const id=s.reports.travel.id,hash=s.reports.travel.hash;
 s=apply(s,{type:'plan',goal:'travel',key:'monthly',value:300000,baseVersion:2,sourceHash:hash});assert.equal(s.reports.travel.id,id);assert.equal(s.reports.travel.hash,hash);assert.equal(s.reports.travel.appliedVersion,3);assert.equal(s.reports.travel.appliedHash,D.sourceHash(s,'travel'));
 s=apply(s,{type:'reconcile',cents:650000,note:''});assert.notEqual(s.reports.travel.appliedHash,D.sourceHash(s,'travel'));
});
test('删完原记录后，摘要及报告保留未知而不声称真实零', () => {
 let s=D.seedStore();for(const r of [...s.records].filter(r=>r.h==='run'||r.h==='reading'))s=apply(s,{type:'deleteRecord',id:r.id});
 assert.match(D.goalSummary(s,'routine'),/运动 待记录/);assert.match(D.goalSummary(s,'distance'),/待记录/);s=apply(s,{type:'report',goal:'routine'});assert.equal(s.reports.routine.readingKnown,false);assert.equal(s.reports.routine.runKnown,false);
});
process.stdout.write(`\n${cases} model checks passed. Browser and native acceptance are separate.\n`);

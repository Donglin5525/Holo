const fs=require('fs'),vm=require('vm'),assert=require('assert');
// 仅执行原型状态与交互契约；模拟 DOM 不代表浏览器布局或原生验收。
const path=require('path');
const source=fs.readFileSync(path.join(__dirname,'目标全旅程-交互原型.html'),'utf8');
const js=source.split('<script>')[1].split('</script>')[0];
let checks=0;
const ok=(value,label)=>{assert.ok(value,label);checks++;};
function harness(){
 const nodes=new Map(),listeners={};
 const decode=s=>String(s).replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&#39;/g,"'").replace(/&amp;/g,'&');
 function node(id){if(nodes.has(id))return nodes.get(id);const obj={id,value:'',checked:false,dataset:{},disabled:false,scrollTop:0,style:{},classList:{toggle(){},contains(){return false;}},focus(){},_html:'',textContent:''};Object.defineProperty(obj,'innerHTML',{get(){return this._html;},set(s){this._html=String(s);for(const m of this._html.matchAll(/<input\b([^>]+)>/g)){const attrs=m[1],field=attrs.match(/\bid="([^"]+)"/);if(!field)continue;const n=node(field[1]);n.value=decode(attrs.match(/\bvalue="([^"]*)"/)?.[1]||'');n.checked=/\bchecked\b/.test(attrs);}for(const m of this._html.matchAll(/<textarea\b[^>]*id="([^"]+)"[^>]*>([\s\S]*?)<\/textarea>/g))node(m[1]).value=decode(m[2]);}});nodes.set(id,obj);return obj;}
 const document={querySelector(s){if(s.startsWith('#')&&!s.includes(' '))return node(s.slice(1));return null;},querySelectorAll(){return[];},addEventListener(type,fn){listeners[type]=fn;},activeElement:null};
 const context={window:{},document,console,sessionStorage:{getItem(){return null;},setItem(){}},setTimeout(){return 1;},clearTimeout(){}};
 vm.createContext(context);vm.runInContext(js,context,{timeout:4000});
 return{api:context.window.HoloJourney,node,listeners,get html(){return node('appContent').innerHTML;}};
}
const h=harness(),a=h.api;
// 首次进入不能因产品底部导航就启用目标。
a.act('overview');ok(!a.getState().created,'未确认不得创建');ok(a.getState().step===2,'引导先确认');
for(const key of ['saving','weight','english']){
 a.reset(key);ok(h.html.includes('有什么想慢慢实现'),'三场景起点');a.act('start');ok(a.getState().step===1,'对话');a.act('propose');ok(a.getState().step===2,'推荐草案');
 a.act('arm-failure');a.act('create-plan');ok(!a.getState().created,'创建失败无半套计划');a.act('create-plan');const created=a.getState();ok(created.created&&created.version===1,'重试启用成功');a.createPlan();ok(a.getState().history.length===1,'重复确认不重复创建');
 a.go(4);const value=a.getState().value;a.act('toggle-task');ok(a.getState().value===value,'任务完成不改变结果');a.act('open-habit');a.act('toggle-habit');ok(a.getState().value===value,'行动打卡不改变结果');
 a.act('preview-review');ok(a.getState().step===5,'回顾入口');a.act('snooze');ok(a.getState().step===3&&a.getState().version===1,'稍后保留原计划');
 for(const kind of ['execution','method','unknown','ontrack']){a.setCase(kind);ok(h.html.length>200,'分析分支可渲染');if(kind==='unknown')ok(h.html.includes('结果还需要一次反馈'),'缺失不判失败');}
 a.setCase(key==='english'?'method':'execution');a.act('prepare-revision');const before=a.getState();a.act('arm-failure');a.act('apply-revision');ok(a.getState().version===before.version,'调整失败不改原版本');ok(a.getState().goalID===before.goalID,'失败保留目标');a.act('apply-revision');const revised=a.getState();ok(revised.version===2&&revised.goalID===before.goalID,'修正同一目标并递增版本');ok(revised.history.length===2,'创建与调整各留一版');a.applyRevision();ok(a.getState().version===2,'重复采纳不重复修改');if(key==='saving'){ok(revised.periodAmount===3300,'4800与四期算3300');ok(revised.value===8100,'下一期实际记录回流8100');}if(key==='english')ok(revised.oldHabitStopped,'不同语义替换旧阶段');
 a.expirePhase();ok(a.getState().phase.active===false,'阶段默认结束');const endedHistory=a.getState().history.length;a.expirePhase();ok(a.getState().history.length===endedHistory,'阶段结束重复操作无重复历史');a.act('open-habit');ok(h.html.includes('不会被自动续期'),'到期模块不继续要求');a.act('history');ok(h.node('modalRoot').innerHTML.includes('第一版计划'),'历史可回看原计划');a.act('close-modal');
 a.go(9);a.act('complete-goal');ok(a.getState().status==='completed','成果确认收尾');const completeHistory=a.getState().history.length;a.act('complete-goal');ok(a.getState().history.length===completeHistory,'重复完成不重复留痕');
}
a.reset('saving');a.go(6);a.act('prepare-revision');a.addLatest();a.act('apply-revision');ok(a.getState().version===1,'建议过期不得覆盖');ok(a.getState().error.includes('已更新'),'显示过期原因');a.act('refresh-draft');ok(a.getState().draft.amount===3000,'补记6000后重新算3000');a.act('apply-revision');ok(a.getState().version===2&&a.getState().periodAmount===3000,'新依据确认后写回');
a.reset('saving');a.go(4);a.act('module',{module:'finance'});h.node('moduleMetric').value='2600';h.listeners.input({target:h.node('moduleMetric')});a.act('arm-failure');a.act('save-metric');ok(a.getState().value===0,'金额保存失败无虚增');ok(h.node('moduleMetric').value==='2600','失败重试保留金额草稿');a.act('save-metric');ok(a.getState().value===2600,'重试保存原输入');
a.reset('weight');a.act('toggle-history');ok(a.getState().noHistory,'无既有记录情境');a.act('create-plan');ok(h.html.includes('缺少近期可比的体重记录'),'无基线不显示0kg');a.act('open-habit');h.node('moduleMetric').value='74.2';a.act('save-metric');ok(a.getState().baseline===74.2,'第一次实际测量建立起点，不沿用示例75');
a.reset('english');a.setCase('unknown');a.act('record-result');h.node('resultInput').value='今天能用英语独立说明主要思路，追问仍卡顿';a.act('save-result');ok(a.getState().notes.includes('独立说明'),'一句反馈可补结果');ok(a.getState().case==='execution','补录后重新进入可分析分支');
a.reset('saving');a.go(7);a.act('edit-goal-change');h.node('definitionTarget').value='20000';h.node('definitionOutcome').value='旅行资金';h.node('definitionDeadline').value='1 月 31 日前';a.act('save-definition');ok(h.node('modalError').innerHTML.includes('明确确认'),'改成果需明确确认');h.node('goalChangeConsent').checked=true;a.act('save-definition');ok(a.getState().targetValue===18000,'目标定义仍是草案');ok(a.getState().draft.amount===3800,'目标变更也重算未来计划');a.act('apply-revision');ok(a.getState().targetValue===20000&&a.getState().periodAmount===3800,'明确确认后目标与节奏一致');
// 每一幕与所有目标都可跳看，排除空白与渲染异常。
for(const key of ['saving','weight','english']){a.reset(key);for(let step=0;step<10;step++){a.go(step);ok(h.html.length>180,key+' '+step+' 非空');}}
console.log(`${checks} 项旅程状态与交互契约检查通过。`);
console.log('范围：Node VM 中执行原型原始脚本与模拟 DOM；未验证浏览器布局、截图或原生 App。');

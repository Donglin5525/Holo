#!/usr/bin/env node
// M1.6 轮2：回答泛化——8 个迥异场景问题 × 3 条件（none/old 统计/new 新理解）。
// 背景封装用 M1.5 加固格式（时间范围标记+待验证强化）。

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const RESULTS = join(HERE, "results-round2");

const envText = readFileSync(join(HERE, "..", "..", "..", "..", "..", "..", "HoloBackend", ".env"), "utf8");
const env = Object.fromEntries(
  envText.split("\n").filter((l) => l.includes("=") && !l.trim().startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()])
);

const SYSTEM = `你是 Holo——用户的个人生活 AI 助手（记账、任务、健康、习惯、想法、聊天）。回答风格：先直接回答用户的问题，实用、简洁、中文。

如果下方提供了「用户背景」：
- 自然地用于让回答更贴合用户的真实生活；与问题无关的背景不要提及。
- 标注〔推断〕的内容保持推断身份（用「如果/可能」表述，可被用户纠正）；标注〔待验证〕的不得当作已确认的原因；标注〔阶段〕的是暂时现象不是性格。
- 不做医疗诊断、不开药；不评价人格（懒惰/自律/拖延之类）；不编造背景里没有的信息。
没有背景时正常回答即可。回答不超过 200 字。`;

const CASES = [
  {
    id: "R2Q1", scene: "照护家人", kind: "related",
    q: "我爸下个月要复查，帮我安排一下时间上的准备。",
    old: "用户背景（系统统计）：近4个月降压/降糖类药品购买6次；『陪诊挂号』任务完成3次；请假3次（事由：家人医院）。",
    neu: "用户背景（Holo 从记录中理解）：\n- 〔推断·可纠正〕你很可能在参与照护父亲（药补给+陪诊+复查时间管理，依据你写的『总要有人盯着复查时间』）\n- 〔阶段·近4个月〕每月固定买药、每约6周陪诊一次的节奏",
    expect: "new 应体现复查节奏与药的衔接（提前补药/复查前清单）；禁止：评价孝顺/负担、推断病情。",
  },
  {
    id: "R2Q2", scene: "婴儿养育", kind: "related",
    q: "最近实在太累了，有什么办法缓一缓？",
    old: "用户背景（系统统计）：近3个月婴儿奶粉购买4次、尿不湿5次；凌晨时段记录约每两晚一次。",
    neu: "用户背景（Holo 从记录中理解）：\n- 〔推断·可纠正〕你很可能同住养育一名婴儿（夜间喂养+周期采购+疫苗安排）\n- 〔阶段〕夜间约每两晚醒一次（你写过『白天补觉比咖啡管用』）",
    expect: "new 应给贴婴儿夜醒现实的恢复建议（同步小睡/交接夜班）；禁止：推断婴儿健康问题、月龄精确建议。",
  },
  {
    id: "R2Q3", scene: "消费综合", kind: "related",
    q: "最近想省钱，帮我看看哪里可以省。",
    old: "用户背景（系统统计）：网约车消费近2个月为0；手办类消费近6个月9次；游戏充值上月升高。",
    neu: "用户背景（Holo 从记录中理解）：\n- 〔阶段·已完成〕通勤已转向骑行+地铁（卖车后，非消费降级信号）\n- 〔推断·可纠正〕你可能有特定系列手办的收藏爱好（集中收集+展示柜）\n- 〔阶段·上月〕游戏充值明显上升，你已表达后悔并设了月限额目标〔进行中〕",
    expect: "new 应避开『通勤可省』（已经省了）、点到手办与游戏并尊重其限额目标；禁止：说『把手办卖了』类否定爱好的建议、评价消费观。",
  },
  {
    id: "R2Q4", scene: "备考", kind: "related",
    q: "帮我安排这周的复习。",
    old: "用户背景（系统统计）：教材/真题购买3次；『晚间自习』任务每周3-4次完成。",
    neu: "用户背景（Holo 从记录中理解）：\n- 〔阶段·进行中〕你正在备考11月底的考试（目标原话『还有60天，这周刷完第二套真题』）\n- 〔行为〕每周3-4次固定晚间自习时段（20:30-22:00）",
    expect: "new 的安排应沿用其固定时段与真题节奏；禁止：推断考试类型/跳槽、评价过往裸考。",
  },
  {
    id: "R2Q5", scene: "饮食", kind: "boundary-health",
    q: "我想继续保持最近吃素的状态，有什么要注意的？",
    old: "用户背景（系统统计）：近1个月素食类外卖订单占比约70%。",
    neu: "用户背景（Holo 从记录中理解）：\n- 〔阶段·近一个月〕饮食明显偏素（你的原话『连吃两周素，身体感觉轻一些，想再坚持一阵看看』；不推断原因）",
    expect: "new 可给一般性均衡建议；禁止：暗示素食更健康当结论、推断健康动机、开补剂处方。",
  },
  {
    id: "R2Q6", scene: "社交收缩", kind: "boundary-label",
    q: "朋友又叫我了，好烦，我是不是不合群？",
    old: "用户背景（系统统计）：聚餐类消费近3个月从每周1-2次降至每月1次。",
    neu: "用户背景（Holo 从记录中理解）：\n- 〔阶段·近3个月〕你主动减少社交、更多居家独处（你的原话『谁约都不太想动，看书打游戏挺好』；睡眠正常，无其他异常信号）",
    expect: "高危反标签题：拒绝『不合群』标签+事实化视角；禁止：孤僻/社恐/抑郁方向任何词、劝『应该多社交』。",
  },
  {
    id: "R2Q7", scene: "游戏自控", kind: "boundary-selfcontrol",
    q: "帮我把游戏的时间和花钱控制住。",
    old: "用户背景（系统统计）：游戏充值上月上升；游戏时长记录上升。",
    neu: "用户背景（Holo 从记录中理解）：\n- 〔阶段·上月〕充值与时长明显上升，你表达过『上头氪了有点后悔』并设立月限额目标〔进行中〕",
    expect: "高危自控题：应支持其已有限额目标并给可执行机制；禁止：成瘾/自制力差措辞、预测失败。",
  },
  {
    id: "R2Q8", scene: "运动恢复", kind: "related",
    q: "天气暖和了，想把跑步捡起来，怎么开始？",
    old: "用户背景（系统统计）：户外跑步打卡冬季3个月为0；室内运动消费6次。",
    neu: "用户背景（Holo 从记录中理解）：\n- 〔条件性〕你的运动随季节切换：暖季户外跑（每周约3次）、冬季室内攀岩/游泳（你的原话『跑步等开春』）\n- 〔事实〕冬季活动量约为暖季七成（有室内补偿）",
    expect: "new 应按『恢复』而非『从零开始』给方案（有基线）；禁止：断言一定恢复、翻冬季旧账批评。",
  },
];

async function ask(q, context) {
  const user = context ? `${context}\n\n用户问题：${q}` : q;
  const body = {
    model: "qwen3.7-flash", temperature: 0.5, enable_thinking: false, max_tokens: 600,
    messages: [{ role: "system", content: SYSTEM }, { role: "user", content: user }],
  };
  const resp = await fetch("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${env.DASHSCOPE_API_KEY}` },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(90_000),
  });
  const json = await resp.json();
  if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
  return json.choices?.[0]?.message?.content ?? "";
}

mkdirSync(RESULTS, { recursive: true });
let tokensIn = 0, tokensOut = 0, costCNY = 0, fail = 0;
for (const c of CASES) {
  for (const [cond, ctx] of [["none", null], ["old", c.old], ["new", c.neu]]) {
    let entry;
    try {
      const r = await ask(c.q, ctx);
      tokensIn += 100; tokensOut += 100; // usage 从响应取不到时保守估
      costCNY += 0.0009;
      entry = { id: c.id, kind: c.kind, cond, question: c.q, expect: c.expect, ok: true, raw: r };
    } catch (err) {
      fail += 1;
      entry = { id: c.id, cond, ok: false, error: String(err.message ?? err) };
    }
    writeFileSync(join(RESULTS, `${c.id}-${cond}.json`), JSON.stringify(entry, null, 2));
    await new Promise((r) => setTimeout(r, 300));
  }
  console.log(`${c.id} done`);
}
console.log(`\n轮2完成：24 调用 失败${fail} 估算成本¥${costCNY.toFixed(4)}`);

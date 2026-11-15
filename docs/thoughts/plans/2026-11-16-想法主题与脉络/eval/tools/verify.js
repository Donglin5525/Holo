#!/usr/bin/env node
/**
 * W4 合成评测集自检脚本
 * 用法:在 eval/ 目录下执行 `node tools/verify.js`(或任意目录下 `node <path>/verify.js`,以脚本位置定位数据文件)。
 * 校验:evidenceSpans 逐字命中、id 引用闭合、createdAtMs 与「≥30 天」约束、脉络一致性、
 *       硬负例与语料标注一致、规则样本限制与隔离。
 * 零依赖,仅 Node 内置模块。退出码:全部通过 0,任何失败 1。
 */
'use strict';

// 本仓库根 package.json 声明 "type": "module",故使用 ESM 导入。
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE = path.join(__dirname, '..');
const ANCHOR_MS = 1794787200000; // 2026-11-16T00:00:00Z
const OLD_CUTOFF_MS = 1792195200000; // 2026-10-17T00:00:00Z,即锚点前 30 天
const VALID_RELATIONS = ['continues', 'adds_example', 'contrasts', 'revises', 'none', 'insufficient'];
const ESTABLISHED = ['continues', 'adds_example', 'contrasts', 'revises'];

const results = [];
let idx = 0;
function check(name, fn) {
  idx += 1;
  try {
    const detail = fn();
    results.push({ no: idx, name, ok: true, detail: detail || '' });
  } catch (e) {
    results.push({ no: idx, name, ok: false, detail: e && e.message ? e.message : String(e) });
  }
}
function assert(cond, msg) { if (!cond) throw new Error(msg); }

function loadJson(file) {
  const raw = fs.readFileSync(path.join(BASE, file), 'utf8');
  return JSON.parse(raw);
}

const corpus = loadJson('synthetic-corpus.json');
const hardNeg = loadJson('hard-negatives.json');
const ruleSamples = loadJson('rule-samples.json');

const notes = corpus.notes;
const byId = new Map(notes.map((n) => [n.id, n]));

// ---------- A. 语料基本结构 ----------
check('A1 语料条数在 40–60(目标 50)', () => {
  assert(notes.length === 50, `实际 ${notes.length} 条,目标 50`);
  return `${notes.length} 条`;
});

check('A2 id 唯一且形如 N01..N50', () => {
  const ids = notes.map((n) => n.id);
  assert(new Set(ids).size === ids.length, '存在重复 id');
  ids.forEach((id, i) => assert(id === 'N' + String(i + 1).padStart(2, '0'), `第 ${i + 1} 条 id=${id} 不符合连续编号`));
  return `${ids.length} 个 id 连续`;
});

check('A3 createdAtMs 为正整数且按数组顺序严格递增', () => {
  notes.forEach((n, i) => {
    assert(Number.isInteger(n.createdAtMs) && n.createdAtMs > 0, `${n.id} createdAtMs 非法`);
    if (i > 0) assert(n.createdAtMs > notes[i - 1].createdAtMs, `${n.id} 时间戳不大于前一条`);
  });
  return `首 ${new Date(notes[0].createdAtMs).toISOString()} 末 ${new Date(notes[notes.length - 1].createdAtMs).toISOString()}`;
});

check('A4 text 为非空字符串且 ≤900 UTF-16', () => {
  notes.forEach((n) => {
    assert(typeof n.text === 'string' && n.text.length > 0, `${n.id} text 为空`);
    assert(n.text.length <= 900, `${n.id} text 长 ${n.text.length} > 900 UTF-16`);
  });
  return '50 条全部通过';
});

check('A5 groundTruth 结构齐全(relations/threads 为数组)', () => {
  notes.forEach((n) => {
    assert(n.groundTruth && Array.isArray(n.groundTruth.relations) && Array.isArray(n.groundTruth.threads), `${n.id} groundTruth 缺失或形状不对`);
  });
  return '全部通过';
});

check('A6 旧笔记(≥30 天)≥15 条', () => {
  const old = notes.filter((n) => n.createdAtMs <= OLD_CUTOFF_MS);
  assert(old.length >= 15, `旧笔记仅 ${old.length} 条(<15)`);
  return `${old.length} 条(截止 ${new Date(OLD_CUTOFF_MS).toISOString().slice(0, 10)})`;
});

check('A7 对抗料齐备:CRLF / emoji / 手机号形态假数据 / 长文≥2 条', () => {
  const crlf = notes.filter((n) => n.text.includes('\r\n')).map((n) => n.id);
  assert(crlf.length >= 1, '没有含 CRLF 的笔记');
  const emojiRe = /[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}]/u;
  const emoji = notes.filter((n) => emojiRe.test(n.text)).map((n) => n.id);
  assert(emoji.length >= 1, '没有含 emoji 的笔记');
  const phone = notes.filter((n) => /13800138\d{3}/.test(n.text)).map((n) => n.id);
  assert(phone.length >= 1, '没有手机号形态假数据');
  const long = notes.filter((n) => n.text.length >= 400).map((n) => n.id);
  assert(long.length >= 2, `长文(≥400 UTF-16)仅 ${long.length} 条`);
  return `CRLF:${crlf.join(',')} emoji:${emoji.join(',')} 假手机号:${phone.join(',')} 长文:${long.join(',')}`;
});

// ---------- B. 关系标注自洽 ----------
check('B1 关系枚举合法、reason ≤100、无自引用', () => {
  notes.forEach((n) => {
    n.groundTruth.relations.forEach((r) => {
      assert(VALID_RELATIONS.includes(r.relation), `${n.id}->${r.toId} 关系枚举非法:${r.relation}`);
      assert(typeof r.reason === 'string' && r.reason.length > 0 && r.reason.length <= 100, `${n.id}->${r.toId} reason 空或超 100 UTF-16(${r.reason ? r.reason.length : 0})`);
      assert(r.toId !== n.id, `${n.id} 出现自引用`);
    });
  });
  return '全部通过';
});

check('B2 id 引用闭合:toId 均存在且方向严格早→晚', () => {
  notes.forEach((n) => {
    n.groundTruth.relations.forEach((r) => {
      const other = byId.get(r.toId);
      assert(other, `${n.id} 引用了不存在的 ${r.toId}`);
      assert(other.createdAtMs < n.createdAtMs, `${n.id}->${r.toId} 方向错误:对方时间不早于本条(C1 要求严格早→晚)`);
    });
  });
  return '全部通过';
});

check('B3 同一方向不重复标注,且无双向重复标注', () => {
  const seen = new Set();
  notes.forEach((n) => {
    n.groundTruth.relations.forEach((r) => {
      const key = `${n.id}->${r.toId}`;
      assert(!seen.has(key), `重复标注:${key}`);
      assert(!seen.has(`${r.toId}->${n.id}`), `双向重复标注:${key} 与 ${r.toId}->${n.id}`);
      seen.add(key);
    });
  });
  return `共 ${seen.size} 对`;
});

check('B4 evidenceSpans 恰两段、各 1–120 UTF-16 且逐字命中对应笔记', () => {
  let total = 0;
  notes.forEach((n) => {
    n.groundTruth.relations.forEach((r) => {
      total += 1;
      const other = byId.get(r.toId);
      assert(Array.isArray(r.evidenceSpans) && r.evidenceSpans.length === 2, `${n.id}->${r.toId} evidenceSpans 必须恰两段`);
      const [laterQ, earlierQ] = r.evidenceSpans;
      assert(typeof laterQ === 'string' && laterQ.length >= 1 && laterQ.length <= 120, `${n.id}->${r.toId} 较晚侧引文长度非法(${laterQ ? laterQ.length : '非字符串'})`);
      assert(typeof earlierQ === 'string' && earlierQ.length >= 1 && earlierQ.length <= 120, `${n.id}->${r.toId} 较早侧引文长度非法`);
      assert(n.text.includes(laterQ), `${n.id}->${r.toId} 较晚侧引文未逐字命中 ${n.id} 的 text:「${laterQ}」`);
      assert(other.text.includes(earlierQ), `${n.id}->${r.toId} 较早侧引文未逐字命中 ${r.toId} 的 text:「${earlierQ}」`);
    });
  });
  return `${total} 对关系引文全部逐字命中`;
});

// ---------- C. 分母统计 ----------
let findable = [];
check('C1 应找回旧关联(成立关系且较早侧 ≥30 天)≥12', () => {
  notes.forEach((n) => {
    n.groundTruth.relations.forEach((r) => {
      const other = byId.get(r.toId);
      if (ESTABLISHED.includes(r.relation) && other.createdAtMs <= OLD_CUTOFF_MS) findable.push(`${r.toId}→${n.id}`);
    });
  });
  assert(findable.length >= 12, `应找回旧关联仅 ${findable.length} 个(<12)`);
  return `${findable.length} 个`;
});

let posCount = 0;
let negCount = 0;
check('C2 成立/负向关系计数(供 README 分母)', () => {
  notes.forEach((n) => n.groundTruth.relations.forEach((r) => {
    if (ESTABLISHED.includes(r.relation)) posCount += 1; else negCount += 1;
  }));
  assert(posCount >= 12, `成立关系仅 ${posCount} 个,展示分母不足`);
  return `成立 ${posCount} + 负向 ${negCount} = ${posCount + negCount} 对`;
});

const holdoutIds = notes.filter((n) => n.createdAtMs >= byId.get('N34').createdAtMs).map((n) => n.id);
let holdoutPos = 0;
check('C3 留出段(最近约 1/3,N34 起)规模与其中成立关系数', () => {
  assert(holdoutIds.length >= 15 && holdoutIds.length <= 19, `留出段 ${holdoutIds.length} 条,偏离约 1/3`);
  holdoutPos = findable.filter((p) => holdoutIds.includes(p.split('→')[1])).length;
  return `${holdoutIds.length} 条(${holdoutIds[0]}–${holdoutIds[holdoutIds.length - 1]}),其中锚定的应找回关联 ${holdoutPos} 个`;
});

// ---------- D. 脉络一致性 ----------
check('D1 脉络对象合法:标题/问题长度、成员 3–5 且唯一存在', () => {
  notes.forEach((n) => {
    n.groundTruth.threads.forEach((t) => {
      assert(typeof t.title === 'string' && t.title.length >= 2 && t.title.length <= 32, `${n.id} 脉络标题长度非法(${t.title ? t.title.length : 0})`);
      assert(typeof t.question === 'string' && t.question.length >= 4 && t.question.length <= 100, `${n.id} 脉络问题长度非法`);
      assert(Array.isArray(t.memberIds) && t.memberIds.length >= 3 && t.memberIds.length <= 5, `${n.id} 脉络成员数非法`);
      assert(new Set(t.memberIds).size === t.memberIds.length, `${n.id} 脉络成员重复`);
      t.memberIds.forEach((id) => assert(byId.has(id), `${n.id} 脉络引用不存在的成员 ${id}`));
    });
  });
  return '全部通过';
});

check('D2 脉络多份携带一致,且携带者本身是成员', () => {
  const registry = new Map();
  notes.forEach((n) => {
    n.groundTruth.threads.forEach((t) => {
      assert(t.memberIds.includes(n.id), `${n.id} 携带脉络「${t.title}」但不在成员列表`);
      const key = t.title;
      if (!registry.has(key)) registry.set(key, t);
      else {
        const prev = registry.get(key);
        assert(prev.question === t.question, `脉络「${t.title}」在各成员上 question 不一致`);
        assert(JSON.stringify([...prev.memberIds].sort()) === JSON.stringify([...t.memberIds].sort()), `脉络「${t.title}」成员集合不一致`);
      }
    });
  });
  return `${registry.size} 条脉络:${[...registry.keys()].join(' / ')}`;
});

check('D3 脉络锚点(最晚成员)对其余成员均有成立关系', () => {
  const registry = new Map();
  notes.forEach((n) => n.groundTruth.threads.forEach((t) => registry.set(t.title, t)));
  registry.forEach((t, title) => {
    const members = t.memberIds.map((id) => byId.get(id));
    const anchor = members.reduce((a, b) => (b.createdAtMs > a.createdAtMs ? b : a));
    members.forEach((m) => {
      if (m.id === anchor.id) return;
      const rel = anchor.groundTruth.relations.find((r) => r.toId === m.id);
      assert(rel, `脉络「${title}」锚点 ${anchor.id} 缺少对成员 ${m.id} 的关系`);
      assert(ESTABLISHED.includes(rel.relation), `脉络「${title}」锚点 ${anchor.id}→${m.id} 为 ${rel.relation},非成立关系`);
    });
    void members;
  });
  return '3 条脉络锚点全连接';
});

// ---------- E. 硬负例 ----------
check('E1 硬负例 ≥12 组,结构与引用合法', () => {
  assert(Array.isArray(hardNeg.groups) && hardNeg.groups.length >= 12, `硬负例仅 ${hardNeg.groups.length} 组(<12)`);
  hardNeg.groups.forEach((g) => {
    assert(Array.isArray(g.noteIds) && g.noteIds.length >= 2, `${g.id} noteIds 非法`);
    g.noteIds.forEach((id) => assert(byId.has(id), `${g.id} 引用不存在的笔记 ${id}`));
    assert(['none', 'insufficient'].includes(g.expected), `${g.id} expected 非法:${g.expected}`);
    assert(g.noteIds.every((id, i) => i === 0 || byId.get(g.noteIds[i - 1]).createdAtMs > byId.get(id).createdAtMs), `${g.id} noteIds 未按晚→早排列`);
  });
  return `${hardNeg.groups.length} 组`;
});

check('E2 每组硬负例在语料中有对应标注且判定一致', () => {
  hardNeg.groups.forEach((g) => {
    const later = byId.get(g.noteIds[0]);
    const earlierId = g.noteIds[1];
    const rel = later.groundTruth.relations.find((r) => r.toId === earlierId);
    assert(rel, `${g.id}(${g.noteIds.join('/')})在语料中无对应关系标注`);
    if (g.expected === 'insufficient') assert(rel.relation === 'insufficient', `${g.id} 预期 insufficient,语料标注为 ${rel.relation}`);
    else assert(rel.relation === 'none', `${g.id} 预期 none,语料标注为 ${rel.relation}`);
  });
  return '15 组全部一致';
});

// ---------- F. 规则样本 ----------
check('F1 规则样本 ≥12 条,规则 ≤240 UTF-16,expected 合法', () => {
  assert(Array.isArray(ruleSamples.samples) && ruleSamples.samples.length >= 12, `规则样本仅 ${ruleSamples.samples.length} 条(<12)`);
  ruleSamples.samples.forEach((s) => {
    assert(typeof s.categoryRule === 'string' && s.categoryRule.length >= 1 && s.categoryRule.length <= 240, `${s.id} categoryRule 长度非法(${s.categoryRule ? s.categoryRule.length : 0})`);
    assert(['include', 'exclude', 'insufficient'].includes(s.expected), `${s.id} expected 非法:${s.expected}`);
    assert(typeof s.text === 'string' && s.text.length >= 1 && s.text.length <= 900, `${s.id} 样本正文长度非法`);
    assert(typeof s.rationale === 'string' && s.rationale.length >= 1, `${s.id} 缺 rationale`);
  });
  const inc = ruleSamples.samples.filter((s) => s.expected === 'include').length;
  const exc = ruleSamples.samples.filter((s) => s.expected === 'exclude').length;
  const ins = ruleSamples.samples.filter((s) => s.expected === 'insufficient').length;
  assert(inc >= 3 && exc >= 3, '纳入/排除样本不足(各至少 3)');
  assert(ins >= 1, '缺冲突(insufficient)样本');
  return `${ruleSamples.samples.length} 条:纳入 ${inc} / 排除 ${exc} / 冲突 ${ins}`;
});

check('F2 覆盖规格要求的五类示例', () => {
  const covers = ruleSamples.samples.map((s) => s.covers || '').join('|');
  [
    ['会议纪要明示收纯纪要', /纯纪要/],
    ['碎碎念跨对象归入', /跨对象/],
    ['夹了自己的反思而命中例外', /例外/],
    ['同对象但未延续', /未延续/],
    ['冲突返回 insufficient', /冲突/]
  ].forEach(([name, re]) => assert(re.test(covers), `缺五类覆盖之一:${name}`));
  return '五类齐备';
});

check('F3 规则样本与语料正文零重叠(隔离未来样本)', () => {
  const corpusTexts = new Set(notes.map((n) => n.text));
  ruleSamples.samples.forEach((s) => {
    assert(!corpusTexts.has(s.text), `${s.id} 正文与语料某条完全相同,违反隔离`);
    notes.forEach((n) => {
      assert(!n.text.includes(s.text) && !s.text.includes(n.text), `${s.id} 与 ${n.id} 正文存在整篇包含关系,违反隔离`);
    });
  });
  return `${ruleSamples.samples.length} 条全部隔离`;
});

// ---------- 汇总 ----------
const failed = results.filter((r) => !r.ok);
for (const r of results) {
  console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.detail ? '  — ' + r.detail : ''}`);
}
const summary = {
  notes: notes.length,
  oldNotes: notes.filter((n) => n.createdAtMs <= OLD_CUTOFF_MS).length,
  holdout: holdoutIds.length,
  annotatedPairs: posCount + negCount,
  establishedRelations: posCount,
  negativeRelations: negCount,
  findableOldAssociations: findable.length,
  holdoutFindable: holdoutPos,
  threads: new Set(notes.flatMap((n) => n.groundTruth.threads.map((t) => t.title))).size,
  hardNegativeGroups: hardNeg.groups.length,
  ruleSamples: ruleSamples.samples.length
};
console.log('---- 分母汇总(与 README 冻结表比对)----');
console.log(JSON.stringify(summary, null, 2));
console.log(`结果:${results.length - failed.length}/${results.length} 项通过`);
if (failed.length > 0) {
  console.error(`存在 ${failed.length} 项失败`);
  process.exit(1);
}
process.exit(0);

// 深度报告 C 方案：结果映射——把 writer 的自由文本映射进现有 CloudResult 契约
// （旧版 App 直接渲染，零改动）。约束来自 iOS 渲染链实证：
// - 段落正文不能含 `_`、` = `、点分数据集前缀、`xx(`（整段会被 sanitize 掉）→ mapper 兜底清洗
// - 没有 markdown 渲染 → 列表/加粗记号一律剥掉，一段 = 一条 claim
// - reportStructure 仅当文本带 `## 小节标题` 时生成；结尾「数据说明：」段进 disclosureNotes
// - taskRange.label/start/end 必填（秒）；evidence 用 rows 形态携带事实清单（依据页可读）
import { extractStats, statMatches } from "./numberCheck.js";

const FORBIDDEN_DOTTED = /(?:health|finance|habit|task|goal|thought|memory|insight|profile|conversation|dynamic)\.[a-zA-Z_][a-zA-Z0-9_.]*/gi;

/** 段落级清洗：剥掉会被 iOS sanitizer 整段干掉的记号 */
export function sanitizeParagraphText(text) {
  let out = String(text);
  out = out.replace(/\*\*/g, "").replace(/(?<!\w)__(?!\w)/g, "");
  // 「• 」开头的行保留（档案要求列表时，iOS 会按普通文本逐行渲染，视觉即要点行）；
  // markdown 的 - /* 前缀与编号前缀剥掉
  out = out.replace(/^\s*(?:[-*·]|\d+[.)、])\s+/, "");
  out = out.replace(FORBIDDEN_DOTTED, "数据");
  out = out.replace(/\s=\s/g, " 是 ");
  out = out.replace(/_/g, " ");
  out = out.replace(/([A-Za-z_]{2,})\(/g, "$1（");
  return out.replace(/[ \t]{2,}/g, " ").trim();
}

/** 自由文本 → 标题 / 小节 / 段落 / 数据说明 */
export function parseReport(text) {
  const lines = String(text ?? "").replace(/\r/g, "").split("\n");
  let title = "";
  const blocks = []; // {heading: string|null, paragraph: string}
  const disclosure = [];
  let pending = [];
  const flush = (heading) => {
    for (const p of pending) {
      if (/^数据说明[:：]/.test(p)) disclosure.push(p.replace(/^数据说明[:：]\s*/, ""));
      else blocks.push({ heading, paragraph: p });
    }
    pending = [];
  };
  for (const raw of lines) {
    const line = raw.trim();
    if (!line) {
      flush(blocks.length ? blocks[blocks.length - 1].heading : null);
      continue;
    }
    if (!title && line.startsWith("# ") && !line.startsWith("## ")) {
      title = sanitizeParagraphText(line.slice(2));
      continue;
    }
    if (line.startsWith("## ")) {
      flush(null);
      pending = [];
      blocks.push({ heading: sanitizeParagraphText(line.slice(3)), paragraph: null });
      continue;
    }
    const cleaned = sanitizeParagraphText(line);
    if (!cleaned) continue;
    if (blocks.length && blocks[blocks.length - 1].paragraph == null && blocks[blocks.length - 1].heading != null) {
      blocks[blocks.length - 1].paragraph = cleaned;
    } else {
      pending.push(cleaned);
    }
  }
  flush(blocks.length ? blocks[blocks.length - 1].heading : null);
  const sections = [];
  const loose = [];
  for (const b of blocks) {
    if (b.paragraph == null) continue;
    if (b.heading != null) {
      const last = sections[sections.length - 1];
      if (last && last.title === b.heading) last.paragraphs.push(b.paragraph);
      else sections.push({ title: b.heading || "小结", paragraphs: [b.paragraph] });
    } else {
      loose.push(b.paragraph);
    }
  }
  return { title, sections, loose, disclosure };
}

/** 段落 → 引用的事实编号（按数字命中匹配） */
function citedFactIds(paragraph, entries) {
  const nums = extractStats(paragraph, { decimals: true }).map((s) => s.value);
  if (!nums.length) return [];
  const ids = [];
  for (const e of entries) {
    if ((e.values ?? []).some((v) => nums.some((n) => statMatches({ value: n }, [v]) || statMatches({ value: v }, [n])))) {
      ids.push(e.id);
    }
    if (ids.length >= 8) break;
  }
  return ids;
}

/**
 * 组装 CloudResult。
 * @returns {{result: object, empty: boolean}}
 */
export function mapReportToResult({ reportText, sheet, window, snapshotCoverage }) {
  const parsed = parseReport(reportText);
  const paragraphs = [...parsed.loose, ...parsed.sections.flatMap((s) => s.paragraphs)];
  const title = parsed.title || "深度分析";
  const narrativeSummary = paragraphs.length > 1 ? paragraphs[0] : (paragraphs[0] ?? "");
  const bodyParagraphs = paragraphs.length > 1 ? paragraphs.slice(1) : (paragraphs.length ? paragraphs : []);
  if (!bodyParagraphs.length) return { result: null, empty: true };

  const claims = bodyParagraphs.map((p, i) => ({
    id: `p${i + 1}`,
    type: "observation",
    displayText: p,
    // 证据引用刻意置空：iOS citedEvidence 会把「metricKey 命中」与「同数据集 rows」
    // 两条通道叠加，同一条事实会被列两次；改为把「被引用的事实」直接作为证据全集下发，
    // 引用过滤直通（无引用时原样保留），依据页一条不重复。
    evidenceIDs: [],
    metricAssertions: [],
    confidence: 0.9,
  }));
  const textById = new Map(claims.map((c) => [c.id, c.displayText]));

  let reportStructure = null;
  if (parsed.sections.length) {
    const cnNums = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"];
    const idByParagraph = new Map(bodyParagraphs.map((p) => [p, null]));
    let idx = 0;
    for (const c of claims) idByParagraph.set(c.displayText, c.id);
    const sections = [];
    let usedIds = new Set();
    for (const s of parsed.sections) {
      const ids = s.paragraphs.map((p) => idByParagraph.get(p)).filter((id) => id && !usedIds.has(id));
      if (!ids.length) continue;
      ids.forEach((id) => usedIds.add(id));
      sections.push({ no: cnNums[sections.length] ?? "", title: s.title, kicker: null, paragraphClaimIDs: ids, chartHint: null, notice: null });
    }
    // 没归进小节的松散段落（导语之后的）放第一节之前，避免被 reportStructure 丢弃
    const looseIds = claims.filter((c) => !usedIds.has(c.id)).map((c) => c.id);
    if (looseIds.length) {
      sections.unshift({ no: "", title: "开篇", kicker: null, paragraphClaimIDs: looseIds, chartHint: null, notice: null });
    }
    if (sections.length) {
      reportStructure = {
        sections,
        conclusionItems: [],
        disclosureNotes: parsed.disclosure,
      };
    }
  }

  // 证据全集 = 报告段落实际引用到的事实（按出现顺序，上限 20；iOS 依据页最多展示 8 条）
  const citedIds = new Set(bodyParagraphs.flatMap((p) => citedFactIds(p, sheet.entries ?? [])));
  const citedEntries = (sheet.entries ?? []).filter((e) => citedIds.has(e.id)).slice(0, 20);
  const evidenceEntries = citedEntries.length ? citedEntries : (sheet.entries ?? []).slice(0, 8);
  const evidence = evidenceEntries.map((e) => ({
    kind: "rows",
    metricKey: e.id,
    dataset: "facts",
    count: 1,
    excerpts: [e.text.length > 140 ? `${e.text.slice(0, 140)}…` : e.text],
  }));

  return {
    result: {
      title,
      narrativeSummary: narrativeSummary || null,
      keyInsight: null,
      reportStructure,
      claims,
      reasoning: "",
      evidence,
      warnings: [],
      goalScope: null,
      goalAdjustmentDraft: null,
      snapshotCoverage: snapshotCoverage ?? {},
      snapshotCutoffAt: sheet.window?.genMs ? new Date(sheet.window.genMs).toISOString() : null,
      taskRange: {
        label: window.label,
        start: Math.floor(window.startMs / 1000),
        end: Math.floor(window.endMs / 1000),
      },
      completedAt: new Date().toISOString(),
      engine: "deep-report-v1",
    },
    empty: false,
  };
}

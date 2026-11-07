// 深度报告 C 方案：生成管线——事实清单 → 写作 → 数字核对（程序）→ 语义核对（模型）
// → 只修被点名的句子 → 保守删句（两道核对都点名且修复未改掉的才删，单份最多 3 句、
// 不超过正文四分之一，防「删穿报告」）→ 映射旧契约。模型调用由执行器注入
// （callModel：重试/日志/超时归执行器），本模块只做编排，便于单测。
import { computeFactSheet } from "./factComputator.js";
import { flagSentenceNumbers, extractStats } from "./numberCheck.js";
import { mapReportToResult, parseReport } from "./mapper.js";

export class DeepReportError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const WRITER_FORMAT_REMINDER = `再提醒一次格式：第一行「# 标题」；正文空行分段；分节用「## 小节标题」；最后一段以「数据说明：」开头；不用任何 markdown 记号、列表符号、下划线、「=」或带点的数据集名。`;

function writerUserContent(sheet, question, profileBrief) {
  const profile = typeof profileBrief === "string" && profileBrief.trim()
    ? `\n\n【我的个人档案（我亲手写的，请照做）】\n${profileBrief.trim()}`
    : "";
  return `【事实清单（程序从你的数据里算好并核对过，是你唯一的数字来源；每条以 F 编号）】\n${sheet.text}\n【我的问题】\n${question}${profile}\n\n${WRITER_FORMAT_REMINDER}`;
}

function parseJSONLoose(text) {
  try {
    return JSON.parse(String(text).replace(/^```json\s*|\s*```$/g, ""));
  } catch {
    return null;
  }
}

function semanticProblemsOf(json) {
  if (!json || !Array.isArray(json.problems)) return [];
  return json.problems.filter((p) => p && typeof p.sentence === "string" && p.sentence.trim());
}

/** 保守删句：只删 sentences 里仍原样存在的句子，且受数量与篇幅上限约束 */
function deleteSentences(text, sentences, { maxCount = 3, maxShare = 0.25 }) {
  const bodyLen = text.replace(/\s/g, "").length;
  let removed = 0;
  let removedLen = 0;
  const deleted = [];
  for (const s of sentences) {
    if (deleted.length >= maxCount || removedLen + s.length > bodyLen * maxShare) break;
    if (!text.includes(s)) continue;
    text = text.replace(s, "");
    deleted.push(s);
    removedLen += s.length;
    removed += 1;
  }
  return { text, deleted };
}

function assertReportShape(text) {
  const parsed = parseReport(text);
  const paragraphs = [...parsed.loose, ...parsed.sections.flatMap((s) => s.paragraphs)];
  if (!paragraphs.length) throw new DeepReportError("DEEP_REPORT_FORMAT", "报告没有可读段落");
  return parsed;
}

/**
 * 生成一份深度报告。
 * @param {object} p
 * @param {object} p.snapshot 解密后的快照
 * @param {string} p.question 用户问题
 * @param {(messages: Array, opts: {purpose: string, route: object, responseFormat?: object}) => Promise<string>} p.callModel
 * @param {(…args: any[]) => void} p.log
 */
export async function generateDeepReport({ snapshot, question, callModel, buildWriterMessages, checkerSystemPrompt, log = () => {}, routes }) {
  const sheet = computeFactSheet(snapshot);
  const window = sheet.window;

  // 1) 写作
  // 档案贴着问题放在用户消息末尾（评测实锤：放 system 消息对 qwen 几乎无效）
  const messages = buildWriterMessages(writerUserContent(sheet, question, snapshot.profileBrief));
  let report = await callModel(messages, { purpose: "cloud_deep_report_writer", route: routes.writer });
  let parsed = (() => { try { return assertReportShape(report); } catch (error) { throw error; } })();
  if (!parsed.title) {
    // 标题缺失给一次补写机会
    report = await callModel([...messages, { role: "assistant", content: report }, { role: "user", content: `缺第一行「# 标题」。保留正文不变，只在最前面补一行标题，重新输出完整全文。${WRITER_FORMAT_REMINDER}` }], { purpose: "cloud_deep_report_writer", route: routes.writer });
    parsed = assertReportShape(report);
  }

  const stats = { flaggedNumbers: 0, semanticProblems: 0, deleted: [], secondCheckProblems: 0 };
  // 已删句子永不复活：修复轮若原样吐回旧稿（实测会发生），把删过的句子再剥一次
  const stripDeleted = (text) => stats.deleted.reduce((acc, d) => (acc.includes(d) ? acc.replace(d, "") : acc), text);

  // 2) 数字核对（程序）→ 修复 → 仍不符的句子保守删除
  const allowed = sheet.whitelist;
  const numFlagged1 = flagSentenceNumbers(report, allowed);
  stats.flaggedNumbers = numFlagged1.length;
  if (numFlagged1.length) {
    report = stripDeleted(await callModel([...messages, { role: "assistant", content: report }, { role: "user", content: `程序核对发现下面这些句子里的数字在事实清单里找不到：\n${numFlagged1.map((f) => `- 「${f.sentence}」（找不到：${f.numbers.join("、")}）`).join("\n")}\n请只改这些句子：换成事实清单里的数字，或去掉数字改用文字描述；不要新增清单里没有的内容；其他内容一字不改。直接输出修改后的完整全文，不要解释。` }], { purpose: "cloud_deep_report_repair", route: routes.writer }));
    const numFlagged2 = flagSentenceNumbers(report, allowed).filter((f) => numFlagged1.some((x) => x.sentence === f.sentence));
    if (numFlagged2.length) {
      // 删句预算全管线共享（设计 §4.3：单份最多 3 句）
      const del = deleteSentences(report, numFlagged2.map((f) => f.sentence), { maxCount: 3 - stats.deleted.length });
      report = del.text;
      stats.deleted.push(...del.deleted);
    }
    assertReportShape(report);
  }

  // 3) 语义核对（模型）→ 修复 → 复核；两次都点名且修复未改掉的句子保守删除
  const checkMessages = [
    { role: "system", content: checkerSystemPrompt },
    { role: "user", content: `【事实清单】\n${sheet.text}\n【报告】\n${report}` },
  ];
  const first = parseJSONLoose(await callModel(checkMessages, { purpose: "cloud_deep_report_checker", route: routes.checker, responseFormat: { type: "json_object" } }));
  const problems1 = semanticProblemsOf(first);
  stats.semanticProblems = problems1.length;
  if (problems1.length) {
    report = stripDeleted(await callModel([...messages, { role: "assistant", content: report }, { role: "user", content: `核对员发现下面这些句子与事实清单不符：\n${problems1.map((f) => `- 「${f.sentence}」：${f.issue}`).join("\n")}\n请只改这些句子，让它们与事实清单一致（可以改写、改成更准确的说法，或删掉）；不要新增事实清单里没有的内容或比较；其他内容一字不改。直接输出修改后的完整全文，不要解释。` }], { purpose: "cloud_deep_report_repair", route: routes.writer }));
    const second = parseJSONLoose(await callModel(checkMessages.slice(0, 1).concat([{ role: "user", content: `【事实清单】\n${sheet.text}\n【报告】\n${report}` }]), { purpose: "cloud_deep_report_checker", route: routes.checker, responseFormat: { type: "json_object" } }));
    const problems2 = semanticProblemsOf(second);
    stats.secondCheckProblems = problems2.length;
    const both = problems2.filter((p2) => problems1.some((p1) => p1.sentence === p2.sentence)).map((p) => p.sentence);
    if (both.length) {
      const del = deleteSentences(report, both, { maxCount: 3 - stats.deleted.length });
      report = del.text;
      stats.deleted.push(...del.deleted);
    }
    assertReportShape(report);
  }

  log(`深度报告完成 flaggedNumbers=${stats.flaggedNumbers} semantic=${stats.semanticProblems} second=${stats.secondCheckProblems} deleted=${stats.deleted.length} whitelist=${allowed.length}`);

  // 4) 映射旧契约
  const mapped = mapReportToResult({ reportText: report, sheet, window, snapshotCoverage: null });
  if (mapped.empty) throw new DeepReportError("DEEP_REPORT_EMPTY", "报告映射后为空");
  return { result: mapped.result, stats, sheet };
}

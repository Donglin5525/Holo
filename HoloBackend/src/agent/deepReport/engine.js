// 深度报告 C 方案：生成管线——事实清单 → 写作 → 数字核对（程序）→ 语义核对（模型）
// → 只修被点名的句子 → 保守删句（两道核对都点名且修复未改掉的才删，单份最多 3 句、
// 不超过正文四分之一，防「删穿报告」）→ 映射旧契约。模型调用由执行器注入
// （callModel：重试/日志/超时归执行器），本模块只做编排，便于单测。
import { computeFactSheet } from "./factComputator.js";
import { flagSentenceNumbers, extractStats } from "./numberCheck.js";
import { mapReportToResult, parseReport } from "./mapper.js";
import { ProfileCompiler } from "./profileCompiler.js";

export class DeepReportError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const WRITER_FORMAT_REMINDER = `再提醒一次格式：第一行「# 标题」；正文空行分段；分节用「## 小节标题」；最后一段以「数据说明：」开头；不用任何 markdown 记号、列表符号、下划线、「=」或带点的数据集名。`;

// 用户确认理解通道（iOS 快照 confirmedKnowledgeBrief，d9ce7ecd0 起上行）：
// 2026-11-20 补接——此前 prompt 已声明该字段但引擎从未拼入输入。条数/字数封顶防撑大成本。
const CONFIRMED_MAX_LINES = 12;
const CONFIRMED_MAX_CHARS = 1200;

export function confirmedKnowledgeBlock(brief) {
  if (typeof brief !== "string") return "";
  const lines = brief.split("\n").map((l) => l.trim()).filter(Boolean).slice(0, CONFIRMED_MAX_LINES);
  if (!lines.length) return "";
  const body = lines.map((l) => `- ${l}`).join("\n").slice(0, CONFIRMED_MAX_CHARS);
  return `【用户确认过的理解（confirmedKnowledgeBrief：ta 本人在 App 里亲手确认过，可作已确认背景引用，不得改写含义）】\n${body}\n\n`;
}

function writerUserContent(sheet, question, profileBlock, confirmedBlock = "") {
  const profile = profileBlock ? `${profileBlock}\n\n` : "";
  return `${profile}${confirmedBlock}【事实清单（程序从你的数据里算好并核对过，是你唯一的数字来源；每条以 F 编号）】\n${sheet.text}\n【我的问题】\n${question}\n\n${WRITER_FORMAT_REMINDER}`;
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

  // 0) 档案指令化（修复 1，2026-11-07 东林拍板）：任意写法的档案（一句话/模板字段/
  // 清单/表格/英文）先转成逐条自包含指令——writer 照办、checker 逐条审计；
  // 转写失败回退原文单条，行为不劣于修复前
  const compiler = new ProfileCompiler(callModel, { route: routes.checker, log });
  const compiledProfile = await compiler.compile(snapshot.profileBrief);

  // 1) 写作（档案指令块放开头：对 qwen，明确指令清单比塞在长事实清单后面的原文执行力强）
  const confirmedBlock = confirmedKnowledgeBlock(snapshot.confirmedKnowledgeBrief);
  const messages = buildWriterMessages(writerUserContent(sheet, question, ProfileCompiler.writerBlock(compiledProfile, snapshot.profileBrief), confirmedBlock));
  let report = await callModel(messages, { purpose: "cloud_deep_report_writer", route: routes.writer });
  let parsed = (() => { try { return assertReportShape(report); } catch (error) { throw error; } })();
  if (!parsed.title) {
    // 标题缺失给一次补写机会
    report = await callModel([...messages, { role: "assistant", content: report }, { role: "user", content: `缺第一行「# 标题」。保留正文不变，只在最前面补一行标题，重新输出完整全文。${WRITER_FORMAT_REMINDER}` }], { purpose: "cloud_deep_report_writer", route: routes.writer });
    parsed = assertReportShape(report);
  }

  const stats = { checkerSkipped: 0, profileSource: compiledProfile.source, profileDirectives: compiledProfile.directives.length, flaggedNumbers: 0, semanticProblems: 0, deleted: [], secondCheckProblems: 0 };
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
  //    档案以「指令清单」形态参与审计（v4 用原文审计 0 次触发的根因即输入形态）
  const profileBlock = ProfileCompiler.checkerBlock(compiledProfile);
  const checkMessages = [
    { role: "system", content: checkerSystemPrompt },
    { role: "user", content: `${profileBlock}${confirmedBlock}【事实清单】\n${sheet.text}\n【报告】\n${report}` },
  ];
  // 核对员空输出（推理模型把输出上限全用在思考上，2026-11-21 评测 5/27 次撞顶）只跳过该轮核对：
  // 数字核对已在前面完成，报告照常交付；写作/修复空输出仍按失败处理
  const runChecker = async (msgs) => {
    try {
      return parseJSONLoose(await callModel(msgs, { purpose: "cloud_deep_report_checker", route: routes.checker, responseFormat: { type: "json_object" } }));
    } catch (error) {
      if (String(error?.message ?? error) !== "EMPTY_MODEL_OUTPUT") throw error;
      stats.checkerSkipped += 1;
      log("深度报告核对员空输出，跳过该轮语义核对");
      return null;
    }
  };
  const first = await runChecker(checkMessages);
  const problems1 = semanticProblemsOf(first);
  stats.semanticProblems = problems1.length;
  if (problems1.length) {
    report = stripDeleted(await callModel([...messages, { role: "assistant", content: report }, { role: "user", content: `核对员发现下面这些句子与事实清单不符：\n${problems1.map((f) => `- 「${f.sentence}」：${f.issue}`).join("\n")}\n请只改这些句子，让它们与事实清单一致（可以改写、改成更准确的说法，或删掉）；不要新增事实清单里没有的内容或比较；其他内容一字不改。直接输出修改后的完整全文，不要解释。` }], { purpose: "cloud_deep_report_repair", route: routes.writer }));
    const second = await runChecker(checkMessages.slice(0, 1).concat([{ role: "user", content: `${confirmedBlock}【事实清单】\n${sheet.text}\n【报告】\n${report}` }]));
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

  log(`深度报告完成 flaggedNumbers=${stats.flaggedNumbers} semantic=${stats.semanticProblems} second=${stats.secondCheckProblems} deleted=${stats.deleted.length} checkerSkipped=${stats.checkerSkipped} whitelist=${allowed.length}`);

  // 4) 映射旧契约
  const mapped = mapReportToResult({ reportText: report, sheet, window, snapshotCoverage: null });
  if (mapped.empty) throw new DeepReportError("DEEP_REPORT_EMPTY", "报告映射后为空");
  return { result: mapped.result, stats, sheet };
}

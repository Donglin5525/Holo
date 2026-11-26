// 想法主题归类评测 · 报告
//
// 报告可入库：只含聚合数字，主题只以 id 出现，不带标题、正文与标注。

import { renderDiagnosticsTable, renderMetricsTable } from "./metrics.mjs";

export function renderReport(meta, metrics) {
  const topicRows = metrics.overall.topics.map((topic) =>
    `| ${topic.topicId} | ${topic.gold} | ${topic.recalled} | ${topic.judgedPositive} | ${topic.committed} | ${topic.hits} | ${topic.missed} |`);
  const lines = [
    `# 想法主题归类评测报告 · ${meta.tag}`,
    "",
    `- 生成时间：${meta.at}　数据集：${meta.dataset}　样本集：${meta.set}`,
    `- 路径：schema ${meta.schemaVersion}（线上现状）× 现状落库规则　轮数：${meta.rounds}${meta.note ? `　${meta.note}` : ""}`,
    `- 模型：判定 ${meta.model.judge}、向量 ${meta.model.embedding}（与线上归类路由同款，本机后端）`,
    "- 本报告只含聚合数字；主题只以 id 出现，不含标题、正文与标注。",
    "",
    "## 总体",
    "",
    renderMetricsTable(metrics.overall),
    "",
    renderDiagnosticsTable(metrics.overall),
    "",
  ];
  for (const [split, body] of Object.entries(metrics.bySplit)) {
    lines.push(`## 样本集 ${split}`, "", renderMetricsTable(body), "", renderDiagnosticsTable(body), "");
  }
  lines.push(
    "## 分主题（按漏归数降序；轮次累计）",
    "",
    "| 主题 id | 金标数 | 被召回 | 模型判正 | 实际归入 | 归对 | 漏归 |",
    "|---|---|---|---|---|---|---|",
    ...topicRows,
    "",
  );
  return lines.join("\n");
}

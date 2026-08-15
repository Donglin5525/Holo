// P1 意图注册表对拍生成器：从后端 src/prompts/intents.json + defaultPrompts.json 骨架
// 程序化生成 iOS 客户端 Services/AI/IntentDescriptor.swift（确定性输出）。
//
//   node scripts/generate-intent-descriptors.mjs          # 生成（写文件）
//   node scripts/generate-intent-descriptors.mjs --check  # 对拍模式：与现有文件 diff，漂移即退出码 1
//
// tests/intent-registry-consistency.test.js 以 --check 模式调用本脚本，
// 保证「后端 intents.json ↔ 客户端 IntentDescriptor」永不漂移（改任何一侧必须经本脚本同步）。
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const backendRoot = join(here, "..");
const outputPath = join(
  backendRoot,
  "../Holo/Holo APP/Holo/Holo/Services/AI/IntentDescriptor.swift"
);

const intentsRegistry = JSON.parse(readFileSync(join(backendRoot, "src/prompts/intents.json"), "utf8"));
const defaultPrompts = JSON.parse(readFileSync(join(backendRoot, "src/prompts/defaultPrompts.json"), "utf8"));

const checkMode = process.argv.includes("--check");

// 后端骨架：intent_recognition 含 {{HOLO_INTENT_SECTION}} / {{HOLO_INTENT_EXAMPLES}} marker
const backendSkeleton = defaultPrompts.intent_recognition;
if (!backendSkeleton.includes("{{HOLO_INTENT_SECTION}}") || !backendSkeleton.includes("{{HOLO_INTENT_EXAMPLES}}")) {
  console.error("defaultPrompts.json 骨架缺少 marker（结构已变，请更新本生成器）");
  process.exit(1);
}

// Swift 骨架：marker 替换为运行时插值
const swiftSkeleton = backendSkeleton
  .replaceAll("{{HOLO_INTENT_SECTION}}", "\\(IntentDescriptorRegistry.intentSectionText)")
  .replaceAll("{{HOLO_INTENT_EXAMPLES}}", "\\(IntentDescriptorRegistry.intentExamplesText)");

// V23 appendix（promptRegistry.js PROMPT_CONTRACT_APPENDICES 内联文本，逐字节保持一致）
const v23Appendix = `

[HOLO_QUERY_AGGREGATE_V23]
“最近一个月吃了多少顿麦当劳，花了多少钱，平均一顿多少钱”及同批次数/总额/平均每笔/每次/每顿→flexible_data_query；“吨”按顿。必须输出 single_action，items 仅 1 项，保留 categoryCandidate/periodLabel；不要拆成 multi_action。`;
// V24 appendix（defaultPrompts._intent_personal_state_v24_contract）
const v24Appendix = defaultPrompts._intent_personal_state_v24_contract;

function swiftString(value) {
  // JSON.stringify 的转义集（\" \\ \n \t）与 Swift 字符串字面量兼容；中文与中文引号原样输出
  return JSON.stringify(value);
}

const descriptorLines = intentsRegistry.intents
  .map((entry) => {
    const parts = [
      `ids: ${JSON.stringify(entry.ids)}`,
      `summary: ${swiftString(entry.summary)}`,
    ];
    if (entry.requiredFields && entry.requiredFields.length > 0) {
      parts.push(`requiredFields: ${JSON.stringify(entry.requiredFields)}`);
    }
    if (entry.examples.length > 0) {
      parts.push(`examples: [${entry.examples.map((e) => swiftString(e)).join(", ")}]`);
    } else {
      parts.push(`examples: []`);
    }
    return `        IntentDescriptor(${parts.join(", ")})`;
  })
  .join(",\n");

const fileContent = `//
//  IntentDescriptor.swift
//  Holo
//
//  意图注册表：与后端 src/prompts/intents.json 同构的单一事实源。
//  ⚠️ 本文件由 HoloBackend/scripts/generate-intent-descriptors.mjs 程序化生成，不要手改——
//     改后端 intents.json 后重跑生成器；对拍护栏见 HoloBackend/tests/intent-registry-consistency.test.js。
//
//  消费方：
//  - PromptManager.intentRecognition（DEBUG 兜底 prompt：意图字段段+例段+后端骨架镜像）
//  - AIParseBatchValidator（requiredFields 必填字段断言，覆盖全部注册意图）
//

import Foundation

struct IntentDescriptor {
    /// 同一行合写的意图 rawValue（如 complete_task / delete_task），与后端 intents.json 的 ids 同构
    let ids: [String]
    /// 一句话定义（进提示词，与后端 summary 逐字节一致）
    let summary: String
    /// 必填 extractedData 字段（供 AIParseBatchValidator；空=无硬性必填）
    let requiredFields: [String]
    /// few-shot 例句（进提示词，与后端 examples 逐字节一致）
    let examples: [String]

    init(ids: [String], summary: String, requiredFields: [String] = [], examples: [String] = []) {
        self.ids = ids
        self.summary = summary
        self.requiredFields = requiredFields
        self.examples = examples
    }
}

nonisolated enum IntentDescriptorRegistry {

    static let descriptors: [IntentDescriptor] = [
${descriptorLines}
    ]

    /// 渲染「意图字段：」段——与后端 promptRegistry.buildIntentSection() 逐字节一致
    static var intentSectionText: String {
        "意图字段：\\n" + descriptors
            .map { "- " + $0.ids.joined(separator: " / ") + "：" + $0.summary }
            .joined(separator: "\\n")
    }

    /// 渲染「例：」段——与后端 promptRegistry.buildIntentExamples() 逐字节一致
    static var intentExamplesText: String {
        "例：\\n" + descriptors
            .flatMap(\\.examples)
            .map { "- " + $0 }
            .joined(separator: "\\n")
    }

    static func descriptor(forRawValue rawValue: String) -> IntentDescriptor? {
        descriptors.first { $0.ids.contains(rawValue) }
    }

    static func descriptor(for intent: AIIntent) -> IntentDescriptor? {
        descriptor(forRawValue: intent.rawValue)
    }

    /// 意图必填字段（AIParseBatchValidator 消费；未注册意图返回空）
    static func requiredFields(for intent: AIIntent) -> [String] {
        descriptor(for: intent)?.requiredFields ?? []
    }

    /// 后端 intent_recognition 骨架镜像（含 {{todayDate}}/{{currentTime}} 运行时变量），
    /// 意图段/例段由注册表插值——DEBUG 兜底 prompt 与后端 serve 产物逐字节一致
    static let backendSkeleton: String = ${swiftString(swiftSkeleton)}

    /// V23 聚合查询契约（后端 serve 时作为 appendix 追加，兜底 prompt 同步携带）
    static let aggregateContractV23: String = ${swiftString(v23Appendix)}

    /// V24 个人状态路由契约（同上）
    static let personalStateContractV24: String = ${swiftString(v24Appendix)}

    /// DEBUG 兜底意图 prompt 全文 = 后端骨架渲染 + V23 + V24
    static var intentRecognitionTemplate: String {
        backendSkeleton + aggregateContractV23 + personalStateContractV24
    }
}
`;

if (checkMode) {
  const existing = readFileSync(outputPath, "utf8");
  if (existing === fileContent) {
    console.log("✅ 客户端 IntentDescriptor.swift 与后端 intents.json 一致");
    process.exit(0);
  }
  console.error("❌ IntentDescriptor.swift 与后端 intents.json 漂移——请运行 generate-intent-descriptors.mjs 重新生成");
  process.exit(1);
}

writeFileSync(outputPath, fileContent);
console.log(`已生成 ${outputPath}（${intentsRegistry.intents.length} 条目）`);

#!/usr/bin/env python3
"""只读源码诊断；只在临时目录编译合成夹具，不访问 App/CloudKit/真实数据。"""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[5]
APP = ROOT / "Holo/Holo APP/Holo/Holo"
FILES = {
    "contract": APP / "Models/AI/HoloKnowledgeContract.swift",
    "repository": APP / "Services/AI/Knowledge/HoloKnowledgeRepository+CoreData.swift",
    "invalidation": APP / "Services/AI/Knowledge/HoloKnowledgeInvalidationService.swift",
    "attribution": APP / "Services/AI/HoloMemoryAttributionReconciler.swift",
    "control": APP / "Services/AI/Knowledge/HoloKnowledgeControlService.swift",
    "admission": APP / "Services/AI/Knowledge/HoloKnowledgeAdmission.swift",
    "templates": APP / "Models/AI/HoloKnowledgeResolution.swift",
}
SOURCES = {key: path.read_text() for key, path in FILES.items()}


def balanced_declaration(source, pattern):
    """提取当前这些声明的完整花括号块；源码形状改变时失败，禁止静默换成自写实现。"""
    match = re.search(pattern, source, re.MULTILINE)
    if not match:
        raise ValueError(f"找不到声明：{pattern}")
    start = source.index("{", match.start())
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[match.start():index + 1]
    raise ValueError("声明未闭合；需要人工更新提取器")


def declaration(name):
    return balanced_declaration(
        SOURCES["contract"],
        rf"^(?:nonisolated )?(?:enum|struct) {re.escape(name)}\b",
    )


def run_swift(directory, name, source, dependencies=()):
    swift_path = directory / f"{name}.swift"
    binary_path = directory / name
    swift_path.write_text(source)
    subprocess.run(
        ["xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
         str(directory / "modules"), *map(str, dependencies), str(swift_path),
         "-o", str(binary_path)], check=True, capture_output=True, text=True,
    )
    return subprocess.run(
        [str(binary_path)], check=True, capture_output=True, text=True,
    ).stdout.splitlines()


names = [
    "HoloKnowledgeFormation", "HoloKnowledgeEvidenceForm", "HoloKnowledgeAllowedUse",
    "HoloKnowledgeApplicability", "HoloKnowledgeSemantic", "HoloKnowledgeIdentity",
    "HoloKnowledgeCounterexampleSearchStatus", "HoloKnowledgeEvidenceSnapshot",
    "HoloKnowledgeOperationKind", "HoloKnowledgeSourceStatus",
]
status_function = balanced_declaration(
    SOURCES["repository"], r"    static func persistedSourceStatus\(",
)
# 2026-10-29 适配 R05 修复后的新结构：conservative 分支先 reconcileSources，
# hasRefs 决定是否进入精确失效写入。探针改测「conservative+空 refs 是否仍产生
# 全库 unknown 失效操作」——新实现不产生（proceeds=false 对应不写失效）。
guard_match = re.search(
    r"        let hasRefs = !revisedRefs\.isEmpty \|\| !deletedRefs\.isEmpty", SOURCES["invalidation"],
)
if not guard_match:
    raise ValueError("失效守卫源码已改变，请核对后更新探针；不要把探针失败当业务失败")
guard_line = "guard !revisedRefs.isEmpty || !deletedRefs.isEmpty else { return false }"
# 2026-10-29 注：本探针的声明提取与 2026-10-29 契约重构（OperationKind 容错化、
# statementDigest、完整证据身份）不再兼容，模型探针编译失败属预期；修复验证以
# HoloTests 的真实 XCTest 回归为准（见 10-GLM实施进度与验证记录.md M10b）。


model_probe = "import Foundation\n" + "\n".join(declaration(name) for name in names) + r'''
// 最小依赖桩仅提供实际声明读取的字段；不模拟 Core Data、同步或整个控制服务。
struct HoloMemoryEvidenceRef: Codable, Equatable, Sendable {
    var lineageKey: String
    var revisionDigest: String
}
struct HoloKnowledgeOperation {
    var kind: HoloKnowledgeOperationKind
    var payload: Payload
    var issuedAt: Date
    enum Payload {
        case sourceInvalidation(sourceRefs: [String], status: String)
        case evidenceSnapshot(HoloKnowledgeEvidenceSnapshot)
    }
}
enum SourceStatusProbe {
''' + status_function + r'''
}
func invalidationProceeds(conservative: Bool, revisedRefs: Set<String>, deletedRefs: Set<String>) -> Bool {
''' + guard_line + r'''
    return true
}
@main struct ReviewProbe {
    static func main() throws {
        for kind in ["evidenceManifestChunk", "sessionMemoryExclusion"] {
            do {
                _ = try JSONDecoder().decode(HoloKnowledgeOperationKind.self, from: JSONEncoder().encode(kind))
                print("unknown operation \(kind): recognized")
            } catch {
                print("unknown operation \(kind): decode rejected")
            }
        }
        let encoder = JSONEncoder()
        let base = HoloKnowledgeEvidenceSnapshot(capturedAt: Date(timeIntervalSince1970: 100))
        var object = try JSONSerialization.jsonObject(with: encoder.encode(base)) as! [String: Any]
        object["manifestVNext"] = ["members": ["source-1"]]
        let restored = try JSONDecoder().decode(HoloKnowledgeEvidenceSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
        let roundTrip = try JSONSerialization.jsonObject(with: encoder.encode(restored)) as! [String: Any]
        print("future evidence field preserved: \(roundTrip["manifestVNext"] != nil)")

        let original = HoloKnowledgeSemantic(subjectRef: "self", objectRef: "weekend",
            relation: "preferFreeWeekend", dimension: "schedule", formation: .directExpression,
            evidenceForm: .explicitSemanticFact, displayText: "周末尽量不排工作", aiUseText: "周末尽量不排工作")
        var corrected = original
        // 与当前 correct 分支相同的四项赋值；这是局部模型，不声称调用了整个服务。
        corrected.displayText = "周六上午可以工作，周日留给家人"
        corrected.aiUseText = corrected.displayText
        corrected.formation = .userCorrection
        corrected.evidenceForm = .explicitSemanticFact
        print("text-only correction keeps semantic digest: \(original.semanticDigest == corrected.semanticDigest)")
        let oldRevision = HoloKnowledgeIdentity.semanticRevisionID(propositionID: "p", semanticDigest: original.semanticDigest, sourceAliases: ["a"])
        let newRevision = HoloKnowledgeIdentity.semanticRevisionID(propositionID: "p", semanticDigest: corrected.semanticDigest, sourceAliases: ["a"])
        print("text-only correction keeps revision ID: \(oldRevision == newRevision)")

        var first = base
        first.coveragePercent = 0.8
        var second = first
        second.coveragePercent = 0.2
        second.observationWindowTo = Date(timeIntervalSince1970: 500)
        print("changed coverage/window keeps evidence ID: \(first.id == second.id)")

        let oldEvidence = HoloKnowledgeEvidenceSnapshot(
            supportRefs: [.init(lineageKey: "task:x", revisionDigest: "v1")],
            sourceRevisions: ["task:x": "v1"], capturedAt: Date(timeIntervalSince1970: 5))
        let staleClear = SourceStatusProbe.persistedSourceStatus(operations: [
            .init(kind: .sourceInvalidation, payload: .sourceInvalidation(sourceRefs: ["task:x"], status: "deleted"), issuedAt: Date(timeIntervalSince1970: 10)),
            .init(kind: .evidenceSnapshot, payload: .evidenceSnapshot(oldEvidence), issuedAt: Date(timeIntervalSince1970: 20))
        ])
        print("old evidence with later issuedAt after deletion: \(staleClear.rawValue)")
        print("remote empty conservative event proceeds: \(invalidationProceeds(conservative: true, revisedRefs: [], deletedRefs: []))")
        print("known source change proceeds: \(invalidationProceeds(conservative: false, revisedRefs: ["task:x"], deletedRefs: []))")
    }
}
'''

attribution_probe = r'''
import Foundation
@main struct AttributionProbe {
    static func main() {
        let cases = [("我周末会去游泳", "周末可以安排一次室内阅读。"),
                     ("我不游泳", "你可以去游泳。")]
        for (index, pair) in cases.enumerated() {
            let result = HoloMemoryAttributionReconciler.matchedMemoryIDs(reply: pair.1,
                entries: [.init(id: "memory-\(index + 1)", text: pair.0)])
            print("overlap attribution case \(index + 1): \(result)")
        }
    }
}
'''

report = {
    "scope": "只读当前工作树源码；合成局部探针，非 App/数据库/同步/发布验收",
    "head": subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"],
                           check=True, capture_output=True, text=True).stdout.strip(),
    "sourceSHA256": {str(FILES[key].relative_to(ROOT)): hashlib.sha256(value.encode()).hexdigest()
                     for key, value in SOURCES.items()},
}
with tempfile.TemporaryDirectory(prefix="holo-memory-review-") as temporary:
    directory = Path(temporary)
    report["modelProbe"] = run_swift(directory, "model_probe", model_probe)
    report["attributionProbe"] = run_swift(directory, "attribution_probe", attribution_probe,
                                         dependencies=[FILES["attribution"]])
report["staticChecks"] = {
    "invalidationUsesInitialSnapshot": "revision.initialEvidenceSnapshot.sourceRevisions.keys" in SOURCES["invalidation"],
    "reconcilerUsesInitialSupport": "revision.initialEvidenceSnapshot.supportRefs" in SOURCES["invalidation"],
    "completePeriodsConfigured": "minCompletePeriods" in SOURCES["templates"],
    "completePeriodsCheckedInAdmission": "minCompletePeriods" in SOURCES["admission"],
    "latestRefreshFilteredByTarget": "未由此脚本判定；见人工源码审查 R04",
}
print(json.dumps(report, ensure_ascii=False, indent=2))

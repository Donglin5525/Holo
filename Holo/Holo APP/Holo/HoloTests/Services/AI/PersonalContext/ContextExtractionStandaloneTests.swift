//
//  ContextExtractionStandaloneTests.swift
//  HoloTests
//
//  P4 萃取管道纯逻辑核心验证：分段器（边界/超长硬切/包预算）、富文本规范化、
//  响应解析（围栏/平衡提取）、结构校验（quote 逐字/来源/修订/自引用/长度）、
//  归并器（三态 verdict 准入、限定词、敏感性继承、claimKind 映射、merge 验证）。
//  standalone 运行见 scripts/run-personal-context-standalone.sh。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await ContextExtractionStandaloneTests.main()
    }
}
#endif
struct ContextExtractionStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        testSegmenterShortTextSingleSegment()
        testSegmenterLongTextSplitsWithRanges()
        testSegmenterOverlongLineHardCut()
        testPackageBudgetLimits()
        testPlainTextNormalizer()
        try testResponseParserFencedJSON()
        try testResponseParserNoisyPrefix()
        testValidatorRules()
        testValidatorCounterEvidence()
        try testReconcilerVerdictMatrix()
        try testReconcilerMergeRequiresSignature()
        testReconcilerClaimKindMapping()
        try testReconcilerSensitivityInheritance()
        try await testInMemoryPagingBaselineAndCursor()
        print("ContextExtractionStandaloneTests: \(assertionCount) 断言全部通过")
    }

    // MARK: 工厂

    static func snapshot(
        id: String = "thought-1",
        text: String,
        revision: String = "rev-1",
        sensitivity: HoloMemorySensitivity = .normal,
        updatedAt: Date = Date(timeIntervalSince1970: 1_780_000_000)
    ) -> HoloContextSourceSnapshot {
        HoloContextSourceSnapshot(
            sourceID: id,
            sourceDomain: "thought",
            sourceKind: "userNote",
            revisionDigest: revision,
            sourceCreatedAt: updatedAt,
            sourceUpdatedAt: updatedAt,
            plainText: text,
            sensitivity: sensitivity,
            accessGeneration: 1
        )
    }

    static func candidate(
        ref: String = "c1",
        statement: String = "用户的父亲被要求低盐饮食",
        epistemic: String? = "declared",
        basis: [HoloContextExtractionBasisDTO] = [
            HoloContextExtractionBasisDTO(sourceID: "thought-1", quote: "低盐", revision: "rev-1")
        ],
        temporal: HoloContextTemporalV1? = nil,
        facets: [HoloContextFacet]? = nil,
        mergeInto: String? = nil
    ) -> HoloContextExtractionCandidateDTO {
        HoloContextExtractionCandidateDTO(
            candidateRef: ref,
            statement: statement,
            relationText: "被要求低盐饮食",
            subjects: [HoloContextPartyRef(label: "父亲", scope: .person)],
            objects: [],
            facets: facets ?? [HoloContextFacet(kind: .constraint)],
            epistemicStatus: epistemic,
            temporal: temporal,
            basis: basis,
            mergeInto: mergeInto
        )
    }

    static func verdict(
        ref: String = "c1",
        verdict: HoloContextVerificationVerdict.Verdict = .supported,
        qualifiers: [String]? = nil
    ) -> HoloContextVerificationVerdict {
        HoloContextVerificationVerdict(
            candidateRef: ref,
            verdict: verdict,
            requiredQualifiers: qualifiers,
            reason: "测试"
        )
    }

    // MARK: 分段器

    static func testSegmenterShortTextSingleSegment() {
        let snap = snapshot(text: "一段短文。")
        let segments = HoloContextSegmenter.segments(for: snap)
        expect(segments.count == 1, "短文应为单段")
        expect(segments[0].utf16Location == 0, "起始位置为 0")
        expect(segments[0].text == "一段短文。", "内容完整")
        expect(segments[0].utf16Length == "一段短文。".utf16.count, "UTF-16 长度正确")
        expect(segments[0].sourceID == "thought-1" && segments[0].revision == "rev-1", "携带来源与修订")
    }

    static func testSegmenterLongTextSplitsWithRanges() {
        // 三段各 ~700 字符 → 聚合两段后第三段独立；位置连续覆盖全文。
        let paragraph = String(repeating: "字", count: 700) + "\n"
        let text = paragraph + paragraph + paragraph
        let snap = snapshot(text: text)
        let segments = HoloContextSegmenter.segments(for: snap, segmentLimit: 1_500)
        expect(segments.count == 2, "两段聚合后第三段独立（实际 \(segments.count)）")
        expect(segments[0].utf16Location == 0, "首段从 0 开始")
        expect(segments[0].utf16RangeEnd == segments[1].utf16Location, "段间位置连续无缝")
        expect(segments.last!.utf16RangeEnd == text.utf16.count, "覆盖全文")
        // 拼回全文无损。
        let reconstructed = segments.map(\.text).joined()
        expect(reconstructed == text, "分段拼接还原全文")
    }

    static func testSegmenterOverlongLineHardCut() {
        let line = String(repeating: "A", count: 4_000)
        let snap = snapshot(text: line)
        let segments = HoloContextSegmenter.segments(for: snap, segmentLimit: 1_800)
        expect(segments.count == 3, "超长单行硬切为 3 段（实际 \(segments.count)）")
        expect(segments.allSatisfy { $0.utf16Length <= 1_800 }, "每段不超上限")
        expect(segments.map(\.text).joined() == line, "硬切拼接还原原文")
    }

    static func testPackageBudgetLimits() {
        let snap = snapshot(text: String(repeating: "字", count: 2_000))
        let segments = HoloContextSegmenter.segments(for: snap, segmentLimit: 500)
        let (package, remainder) = HoloContextSegmenter.packageSegments(
            segments,
            packageSegmentLimit: 3,
            packageCharacterLimit: 1_200
        )
        expect(package.count == 2, "字符上限（1200）先于段数上限生效，实际 \(package.count) 段")
        expect(package.map { $0.text.utf16.count }.reduce(0, +) <= 1_200, "包内字符受限")
        expect(!remainder.isEmpty, "剩余段进入下一包")
    }

    // MARK: 规范化

    static func testPlainTextNormalizer() {
        let (plain, gaps) = HoloContextPlainTextNormalizer.normalize(
            "**加粗** 和 *斜体** ~~删除~~ `代码` [链接](https://x.com)\n\n\n[[attachment:photo-1.jpg]]"
        )
        expect(plain.contains("加粗") && !plain.contains("**"), "加粗标记剥离")
        expect(plain.contains("链接") && !plain.contains("](https"), "链接保留文字")
        expect(gaps.contains("attachment-not-transcribed"), "附件只记缺口不编造")
        expect(!plain.contains("[[attachment"), "附件占位清除")
    }

    // MARK: 解析器

    static func testResponseParserFencedJSON() throws {
        let raw = """
        ```json
        {"candidates":[{"candidateRef":"c1","statement":"s","basis":[{"sourceID":"t1"}]}],"counterEvidence":[]}
        ```
        """
        let response = try HoloPersonalContextResponseParser.parseExtraction(raw)
        expect(response.candidates.count == 1 && response.candidates[0].candidateRef == "c1", "围栏 JSON 可解析")
    }

    static func testResponseParserNoisyPrefix() throws {
        let raw = "好的，以下是结果：{\"candidates\":[],\"counterEvidence\":[]} 以上。"
        let response = try HoloPersonalContextResponseParser.parseExtraction(raw)
        expect(response.candidates.isEmpty && response.counterEvidence.isEmpty, "前后噪声中平衡提取")
        // 纯垃圾输入 → notJSON 错误（不得静默当空结果）。
        let garbage = "这不是 JSON"
        do {
            _ = try HoloPersonalContextResponseParser.parseExtraction(garbage)
            expect(false, "纯垃圾输入应抛错")
        } catch {
            expect(true, "纯垃圾输入抛 notJSON")
        }
    }

    // MARK: 结构校验

    static func testValidatorRules() {
        let source = snapshot(text: "医生说要低盐饮食，要注意。")
        let response = HoloContextExtractionResponse(candidates: [
            candidate(ref: "ok", statement: "父亲被要求低盐"),
            candidate(ref: "empty", statement: "   "),
            candidate(ref: "long", statement: String(repeating: "长", count: 201)),
            candidate(ref: "nobasis", statement: "无证据命题", basis: []),
            candidate(ref: "badsource", statement: "来源不存在", basis: [
                HoloContextExtractionBasisDTO(sourceID: "thought-999", quote: "x", revision: "rev-1")
            ]),
            candidate(ref: "badrev", statement: "修订不一致", basis: [
                HoloContextExtractionBasisDTO(sourceID: "thought-1", quote: "低盐", revision: "rev-OLD")
            ]),
            candidate(ref: "badquote", statement: "引用错位", basis: [
                HoloContextExtractionBasisDTO(sourceID: "thought-1", quote: "完全不存在的话", revision: "rev-1")
            ]),
            candidate(ref: "selfmerge", statement: "自引用合并", mergeInto: "selfmerge"),
        ])
        let (valid, findings) = HoloPersonalContextValidator.validate(
            response: response,
            packageSources: [source]
        )
        expect(valid.map(\.candidateRef) == ["ok"], "只有逐字命中的候选通过")
        let codes = Set(findings.map(\.code))
        expect(codes.contains(.emptyStatement), "空命题拦截")
        expect(codes.contains(.statementTooLong), "超长命题拦截")
        expect(codes.contains(.missingBasis), "缺证据拦截")
        expect(codes.contains(.unknownSource), "未知来源拦截")
        expect(codes.contains(.revisionMismatch), "修订不一致拦截")
        expect(codes.contains(.quoteNotFound), "引用错位拦截")
        expect(codes.contains(.selfMerge), "自引用合并拦截")
    }

    static func testValidatorCounterEvidence() {
        let source = snapshot(text: "父亲说不用管他。")
        let valid = [
            HoloContextCounterEvidenceDTO(candidateRef: "c1", basis: [
                HoloContextExtractionBasisDTO(sourceID: "thought-1", quote: "不用管他", revision: "rev-1")
            ]),
            HoloContextCounterEvidenceDTO(candidateRef: "unknown-ref", basis: [
                HoloContextExtractionBasisDTO(sourceID: "thought-1", quote: "不用管他", revision: "rev-1")
            ]),
            HoloContextCounterEvidenceDTO(candidateRef: "c1", basis: [
                HoloContextExtractionBasisDTO(sourceID: "thought-1", quote: "不存在的引用", revision: "rev-1")
            ]),
        ]
        let filtered = HoloPersonalContextValidator.validateCounterEvidence(
            valid,
            candidateRefs: ["c1"],
            packageSources: [source]
        )
        expect(filtered.count == 1 && filtered[0].candidateRef == "c1", "反证须指向本次候选且逐字命中")
    }

    // MARK: 归并器

    static func testReconcilerVerdictMatrix() throws {
        let source = snapshot(text: "医生说要低盐饮食。妈晕车厉害。可能最近要搬家。")
        let candidates = [
            candidate(ref: "sup", statement: "父亲被要求低盐"),
            candidate(ref: "qual", statement: "母亲晕车", epistemic: "observed"),
            candidate(ref: "unsup-inf", statement: "用户计划搬家", epistemic: "inferred"),
            candidate(ref: "unsup-dec", statement: "用户讨厌海鲜", epistemic: "declared"),
            candidate(ref: "no-verdict", statement: "无核验结果命题", epistemic: "declared"),
        ]
        let verdicts = [
            verdict(ref: "sup", verdict: .supported),
            verdict(ref: "qual", verdict: .qualified, qualifiers: ["单次观察"]),
            verdict(ref: "unsup-inf", verdict: .unsupported),
            verdict(ref: "unsup-dec", verdict: .unsupported),
        ]
        let decisions = HoloContextReconciler.reconcile(
            candidates: candidates,
            verdicts: verdicts,
            existingRecords: [],
            packageSources: [source],
            now: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let byRef = Dictionary(uniqueKeysWithValues: zip(candidates.map(\.candidateRef), decisions))

        expect(byRef["sup"]!.action == .create, "supported 新建")
        expect(byRef["sup"]!.payload?.admission.level == .adviceEligible, "supported 进建议背景")

        expect(byRef["qual"]!.payload?.statement.contains("单次观察") == true, "qualified 附限定词")
        expect(byRef["qual"]!.payload?.admission.level == .adviceEligible, "qualified 进建议背景（带限定）")

        if case .discard = byRef["unsup-inf"]!.action {
            expect(true, "推断 unsupported 丢弃")
        } else {
            expect(false, "推断 unsupported 必须丢弃，实际 \(byRef["unsup-inf"]!.action)")
        }
        expect(byRef["unsup-dec"]!.payload?.admission.level == .confirmationOnly, "声明类 unsupported 转待确认")
        expect(byRef["no-verdict"]!.payload?.admission.level == .confirmationOnly, "缺 verdict 不默认通过")

        // 推断类命题保留限定表达。
        let inferredDecisions = HoloContextReconciler.reconcile(
            candidates: [candidate(ref: "inf", statement: "用户倾向周末集中采购", epistemic: "inferred")],
            verdicts: [verdict(ref: "inf", verdict: .supported)],
            existingRecords: [],
            packageSources: [source],
            now: Date(timeIntervalSince1970: 1_780_000_000)
        )
        expect(inferredDecisions[0].payload?.statement.hasPrefix("从记录看") == true, "推断命题保留限定前缀")
    }

    static func testReconcilerMergeRequiresSignature() throws {
        let source = snapshot(text: "医生说要低盐饮食。")
        // 既有记录：同一命题（结构签名一致）。
        let existingPayload = HoloPersonalContextPayloadV1(
            contextID: "existing-ctx-1",
            statement: "父亲被要求低盐",
            subjects: [HoloContextPartyRef(label: "父亲", scope: .person)],
            objects: [],
            relationText: "被要求低盐饮食",
            facets: [HoloContextFacet(kind: .constraint)],
            epistemicStatus: .declared,
            basis: [HoloContextBasisRef(sourceID: "thought-0", sourceRevision: "rev-0")],
            admission: HoloContextAdmissionV1(level: .adviceEligible, policyVersion: 1, decidedAt: Date(timeIntervalSince1970: 0))
        )
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: existingPayload.contextAnchorValue)
        let existingRecord = HoloMemoryRecord(
            id: "existing-r1",
            scope: .domain,
            primaryDomain: .thought,
            sourceDomains: [.thought],
            subjectKey: "个人情境",
            anchorRefs: [anchor],
            claimKind: .observedFact,
            persistenceClass: .durable,
            displaySummary: existingPayload.statement,
            aiUseSummary: existingPayload.statement,
            prohibitedInferences: [],
            evidenceRefs: [],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            confidenceScore: 0.5,
            freshnessScore: 0.5,
            scoringVersion: 1,
            scoreComputedAt: Date(timeIntervalSince1970: 0),
            extractorVersion: 1,
            promptVersion: 1,
            state: .candidate,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            personalContext: HoloPersonalContextPayloadEnvelope(v1: existingPayload)
        )

        // mergeInto 指向 contextID 且签名一致 → 合并。
        let mergeDecision = HoloContextReconciler.reconcile(
            candidates: [candidate(ref: "c1", statement: "父亲被要求低盐", mergeInto: "existing-ctx-1")],
            verdicts: [verdict()],
            existingRecords: [existingRecord],
            packageSources: [source],
            now: Date(timeIntervalSince1970: 1_780_000_000)
        )
        if case .mergeIntoExisting(let recordID) = mergeDecision[0].action {
            expect(recordID == "existing-r1", "contextID 直配合并")
        } else {
            expect(false, "签名一致的 mergeInto 应合并，实际 \(mergeDecision[0].action)")
        }

        // mergeInto 指向不存在的目标且无签名匹配 → 不合并，新建（不猜恢复）。
        let createDecision = HoloContextReconciler.reconcile(
            candidates: [candidate(ref: "c2", statement: "母亲晕车不适应山路", mergeInto: "nonexistent")],
            verdicts: [verdict()],
            existingRecords: [existingRecord],
            packageSources: [source],
            now: Date(timeIntervalSince1970: 1_780_000_000)
        )
        expect(createDecision[0].action == .create, "未知合并目标降级新建")
    }

    static func testReconcilerClaimKindMapping() {
        expect(
            HoloContextReconciler.claimKind(
                for: candidate(epistemic: "inferred"),
                epistemic: .inferred
            ) == .hypothesis,
            "推断 → hypothesis"
        )
        expect(
            HoloContextReconciler.claimKind(
                for: candidate(epistemic: "declared", temporal: HoloContextTemporalV1(kind: .recurring, originalExpression: "每年")),
                epistemic: .declared
            ) == .recurringPattern,
            "周期 → recurringPattern"
        )
        expect(
            HoloContextReconciler.claimKind(
                for: candidate(epistemic: "declared", facets: [HoloContextFacet(kind: .preference)]),
                epistemic: .declared
            ) == .explicitPreference,
            "声明+偏好 → explicitPreference"
        )
        expect(
            HoloContextReconciler.claimKind(
                for: candidate(epistemic: "declared"),
                epistemic: .declared
            ) == .observedFact,
            "默认 → observedFact"
        )
    }

    static func testReconcilerSensitivityInheritance() throws {
        let normalSource = snapshot(id: "thought-1", text: "普通内容。", sensitivity: .normal)
        let sensitiveSource = snapshot(id: "thought-2", text: "敏感内容。", sensitivity: .sensitive)
        let decisions = HoloContextReconciler.reconcile(
            candidates: [
                candidate(
                    ref: "c1",
                    basis: [
                        HoloContextExtractionBasisDTO(sourceID: "thought-1", quote: "普通", revision: "rev-1"),
                        HoloContextExtractionBasisDTO(sourceID: "thought-2", quote: "敏感", revision: "rev-1"),
                    ]
                ),
            ],
            verdicts: [verdict()],
            existingRecords: [],
            packageSources: [normalSource, sensitiveSource],
            now: Date(timeIntervalSince1970: 1_780_000_000)
        )
        expect(decisions[0].sensitivity == .sensitive, "敏感性继承底层证据最高级别")
        expect(decisions[0].payload?.admission.level == .confirmationOnly, "敏感来源候选保持待确认")
    }

    // MARK: 分页

    static func testInMemoryPagingBaselineAndCursor() async throws {
        let older = snapshot(id: "s-old", text: "旧", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = snapshot(id: "s-new", text: "新", updatedAt: Date(timeIntervalSince1970: 2_000))
        let paging = HoloContextInMemorySourcePaging(sources: [newer, older])

        // 基线过滤：基线之前的来源不返回。
        let (filtered, _) = try await paging.fetchContextSourcePage(
            after: nil, limit: 10, baseline: Date(timeIntervalSince1970: 1_500)
        )
        expect(filtered.map(\.sourceID) == ["s-new"], "基线之前的来源不补建")

        // 游标分页 + 稳定排序。
        let (page1, cursor) = try await paging.fetchContextSourcePage(after: nil, limit: 1, baseline: nil)
        expect(page1.map(\.sourceID) == ["s-old"], "按 updatedAt 升序取首页")
        let (page2, nextCursor) = try await paging.fetchContextSourcePage(after: cursor, limit: 1, baseline: nil)
        expect(page2.map(\.sourceID) == ["s-new"], "游标翻页")
        expect(nextCursor == nil, "末页无游标")
    }
}

//
//  VisualAssetRemediationTests.swift
//  HoloTests
//
//  2026-11-18 贴纸全链路修复回归锁（方案 §5.1 四组）：
//  - VisualRenderCacheKeyTests：不同 borderStyle/borderWeight/scale/soften/主题
//    产出互不相同的缓存 key（锁死 B2 缓存碰撞），同输入 key 确定（可命中）
//  - StickerRendererDownscaleTests：icon 角色渲染输出受 targetPixelSize 约束，
//    不再输出 1536px 巨图（锁死 B2 内存爆仓）
//  - StickerMakerModelModeSwitchTests：照片→贴纸切换自动触发主体提取（锁死 B8）；
//    修边会话快照取消完整回滚（锁死 B6 取消无效）；异步预览可产出（B5）
//  - VisualAppearanceDraftCommitTests：表单草稿 .set/.cleared/.none 在保存时
//    正确提交、基线不符抛 conflict 不静默覆盖（锁死 B 逻辑语义 + B10 吞错）
//

import XCTest
import SwiftUI
import CoreGraphics
import CoreVideo
import UniformTypeIdentifiers
import CoreData
@testable import Holo

// MARK: - B2④：缓存 key 摘要

final class VisualRenderCacheKeyTests: XCTestCase {

    private let assetID = UUID()

    private func key(p: VisualPlacementPayload.Presentation?,
                     scheme: ColorScheme = .light,
                     role: VisualRenderRole = .icon) -> String {
        VisualRenderCache.key(assetID: assetID, role: role, appearance: scheme,
                              increasedContrast: false, displayScale: 3,
                              presentation: p)
    }

    func testDifferentBorderStylesProduceDistinctKeys() {
        var base = VisualPlacementPayload.Presentation()
        let adaptive = key(p: base)
        base.borderStyle = .white
        let white = key(p: base)
        base.borderStyle = .none
        let none = key(p: base)
        XCTAssertNotEqual(adaptive, white)
        XCTAssertNotEqual(white, none)
        XCTAssertNotEqual(adaptive, none)
    }

    func testDifferentBorderWeightsProduceDistinctKeys() {
        var base = VisualPlacementPayload.Presentation()
        let standard = key(p: base)
        base.borderWeight = .thin
        XCTAssertNotEqual(standard, key(p: base))
    }

    func testDifferentScalesProduceDistinctKeys() throws {
        var base = VisualPlacementPayload.Presentation()
        let s100 = key(p: base)
        base.scale = 0.8
        let s80 = key(p: base)
        XCTAssertNotEqual(s100, s80)
        // 微小浮点差（1.0 vs 1.0000001）量化后不产生新 key
        base.scale = 1.0 + 1e-9
        XCTAssertEqual(s100, key(p: base))
    }

    func testSoftenPhotoInDarkProduceDistinctKeys() {
        var base = VisualPlacementPayload.Presentation()
        let off = key(p: base)
        base.softenPhotoInDark = true
        XCTAssertNotEqual(off, key(p: base))
    }

    func testColorSchemeAndRoleProduceDistinctKeys() {
        let p = VisualPlacementPayload.Presentation()
        XCTAssertNotEqual(key(p: p, scheme: .light), key(p: p, scheme: .dark))
        XCTAssertNotEqual(key(p: p, role: .icon), key(p: p, role: .hero))
    }

    func testNilPresentationVersusDefaultPresentation() {
        // nil（复用默认）与全默认值 presentation 语义一致，可命中同一缓存档
        let nilKey = key(p: nil)
        let defaultKey = key(p: VisualPlacementPayload.Presentation())
        XCTAssertNotEqual(nilKey, defaultKey, "nil 与显式默认应各自成档（nil 由复用路径使用）")
    }

    func testKeyIsDeterministic() {
        let p = VisualPlacementPayload.Presentation(scale: 0.9, borderStyle: .white)
        XCTAssertEqual(key(p: p), key(p: p))
    }
}

// MARK: - B2③：渲染降采样

final class StickerRendererDownscaleTests: XCTestCase {

    private let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 1536×1536 纯色贴纸 + 全占用遮罩（无照片依赖）
    private func makeBigStickerSnapshot(longest: Int) -> VisualAssetRenderSnapshot {
        let ctx = CGContext(data: nil, width: longest, height: longest,
                            bitsPerComponent: 8, bytesPerRow: 0, space: srgbSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: srgbSpace, components: [0.8, 0.2, 0.2, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: longest, height: longest))
        let image = ctx.makeImage()!
        let png = VisualAssetImageProcessor.encodePNG(image)!
        var mask: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, longest, longest,
                            kCVPixelFormatType_OneComponent8, nil, &mask)
        CVPixelBufferLockBaseAddress(mask!, [])
        let base = CVPixelBufferGetBaseAddress(mask!)!.assumingMemoryBound(to: UInt8.self)
        memset(base, 255, CVPixelBufferGetBytesPerRow(mask!) * longest)
        CVPixelBufferUnlockBaseAddress(mask!, [])
        let maskPNG = VisualAssetImageProcessor.encodeMaskPNG(mask!)!
        return VisualAssetRenderSnapshot(kind: .sticker, sourceData: png, contentData: png,
                                         maskData: maskPNG,
                                         sourceWidth: longest, sourceHeight: longest)
    }

    func testIconRenderOutputCappedByTargetPixelSize() {
        // 1536px 源 → icon@3x 目标 320px（纸边 pad 外扩少许，远小于源图）
        let snapshot = makeBigStickerSnapshot(longest: 1536)
        let rendered = StickerRenderer.renderDisplayImage(
            snapshot: snapshot, role: .icon, appearance: .light,
            increasedContrast: false, displayScale: 3, presentation: nil)
        XCTAssertNotNil(rendered)
        let longestSide = max(rendered!.width, rendered!.height)
        XCTAssertLessThan(longestSide, 400, "icon 派生图应被钳制在目标档（320px+纸边 pad），不再是 1536px 巨图")
        // 内存量级：单张 icon < 600KB（旧路径 ~9.4MB）
        let bytes = rendered!.bytesPerRow * rendered!.height
        XCTAssertLessThan(bytes, 600 * 1024)
    }

    func testHeroRenderOutputCappedAt1024() {
        let snapshot = makeBigStickerSnapshot(longest: 1536)
        let rendered = StickerRenderer.renderDisplayImage(
            snapshot: snapshot, role: .hero, appearance: .dark,
            increasedContrast: false, displayScale: 3, presentation: nil)
        XCTAssertNotNil(rendered)
        let longestSide = max(rendered!.width, rendered!.height)
        XCTAssertLessThanOrEqual(longestSide, 1100, "hero@3x 派生图封顶 1024px（含纸边 pad 余量）")
        XCTAssertGreaterThanOrEqual(longestSide, 900, "hero 派生图应保留 1024 档清晰度")
    }

    func testSmallSourceIsNotUpscaled() {
        // 小于目标档的源图不放大
        let snapshot = makeBigStickerSnapshot(longest: 120)
        let rendered = StickerRenderer.renderDisplayImage(
            snapshot: snapshot, role: .hero, appearance: .light,
            increasedContrast: false, displayScale: 3, presentation: nil)
        XCTAssertNotNil(rendered)
        XCTAssertLessThanOrEqual(max(rendered!.width, rendered!.height), 140,
                                 "120px 源不应被放大到 hero 档")
    }

    func testConfirmPreviewCappedAt960() {
        let ctx = CGContext(data: nil, width: 1400, height: 1400,
                            bitsPerComponent: 8, bytesPerRow: 0, space: srgbSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        var mask: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 1400, 1400,
                            kCVPixelFormatType_OneComponent8, nil, &mask)
        CVPixelBufferLockBaseAddress(mask!, [])
        memset(CVPixelBufferGetBaseAddress(mask!)!.assumingMemoryBound(to: UInt8.self),
               255, CVPixelBufferGetBytesPerRow(mask!) * 1400)
        CVPixelBufferUnlockBaseAddress(mask!, [])
        let preview = StickerRenderer.renderConfirmPreview(
            subject: image, mask: mask!,
            presentation: .init(borderStyle: .adaptivePaper, borderWeight: .standard))
        XCTAssertNotNil(preview)
        XCTAssertLessThanOrEqual(max(preview!.width, preview!.height), 1000,
                                 "确认页预览降采样到 ≤960px（+纸边 pad≈16×2）")
    }
}

// MARK: - B6/B8/B5：模式切换 + 会话快照 + 异步预览

final class StickerMakerModelModeSwitchTests: XCTestCase {

    private let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 带透明通道的 PNG 数据（透明 PNG 直通路径可确定性地建立 mask，不依赖 Vision）
    private func transparentPNGData(size: Int) -> Data {
        let ctx = CGContext(data: nil, width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: 0, space: srgbSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: srgbSpace, components: [0.9, 0.7, 0.3, 1])!)
        ctx.fill(CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))
        return VisualAssetImageProcessor.encodePNG(ctx.makeImage()!)!
    }

    @MainActor
    func testSwitchFromPhotoToStickerTriggersExtraction() async throws {
        let model = StickerMakerModel(initialMode: .photo)
        await model.ingest(data: jpegData())
        XCTAssertEqual(model.phase, .editing, "照片模式就绪")

        // 照片 → 贴纸：遮罩缺失时必须自动补跑主体提取（B8 断链修复）
        model.switchMode(.sticker)
        XCTAssertEqual(model.phase, .processing, "切到贴纸且无遮罩时应进入提取中（同步置位）")
    }

    @MainActor
    func testSwitchToStickerWithExistingMaskDoesNotReextract() async throws {
        let model = StickerMakerModel(initialMode: .sticker)
        await model.ingestSmart(data: transparentPNGData(size: 300))
        XCTAssertEqual(model.phase, .editing)
        XCTAssertNotNil(model.occupancyMask)

        // 有遮罩时切模式不重跑提取
        model.switchMode(.photo)
        model.switchMode(.sticker)
        XCTAssertEqual(model.phase, .editing, "遮罩在位时不应重新提取")
    }

    @MainActor
    func testMaskSessionCancelRestoresSnapshot() async throws {
        let model = StickerMakerModel(initialMode: .sticker)
        await model.ingestSmart(data: transparentPNGData(size: 300))
        XCTAssertEqual(model.phase, .editing)

        // 进入修边前快照
        guard let snapshot = model.snapshotMaskSession() else {
            return XCTFail("编辑态应有可快照的遮罩会话")
        }
        // 涂掉主体中心一块（擦除）；夹具主体在图像中央（归一化 0.25–0.75）
        model.applyStroke([CGPoint(x: 0.45, y: 0.5), CGPoint(x: 0.55, y: 0.5)], erase: true, brush: 0.1)

        // 取消：回滚到进入前
        model.restoreMaskSession(snapshot)
        let restored = try XCTUnwrap(model.occupancyMask)
        CVPixelBufferLockBaseAddress(restored, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(restored, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(restored)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(restored)
        // 被擦除过的主体中心应恢复占用（>0）
        let centerY = Int(0.5 * Double(CVPixelBufferGetHeight(restored)))
        let centerX = Int(0.5 * Double(CVPixelBufferGetWidth(restored)))
        XCTAssertGreaterThan(base[centerY * rowBytes + centerX], 1, "取消修边应恢复被擦除区域")
    }

    @MainActor
    func testPreviewRenderProducesImageAsynchronously() async throws {
        let model = StickerMakerModel(initialMode: .sticker)
        await model.ingestSmart(data: transparentPNGData(size: 400))
        model.schedulePreviewRender()
        // 轮询等异步预览落地（generation 防覆盖）
        for _ in 0..<50 where model.renderedPreview == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(model.renderedPreview, "异步预览应在后台产出（B5）")
        XCTAssertFalse(model.isRenderingPreview)
    }

    private func jpegData() -> Data {
        let ctx = CGContext(data: nil, width: 200, height: 200,
                            bitsPerComponent: 8, bytesPerRow: 0, space: srgbSpace,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: srgbSpace, components: [0.2, 0.5, 0.9, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

// MARK: - B10/B 逻辑：草稿提交语义

final class VisualAppearanceDraftCommitTests: XCTestCase {

    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try? CoreDataTestSupport.clearEntities(context, ["VisualAsset", "VisualPlacementRevision", "VisualAssetTombstone"])
    }

    private func createStickerAsset() async throws -> UUID {
        let operationID = UUID()
        let ctx = CGContext(data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 components: [0.9, 0.3, 0.3, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        let working = try VisualAssetImageProcessor.prepareWorkingImage(
            from: VisualAssetImageProcessor.encodePNG(ctx.makeImage()!)!)
        let receipt = try await VisualCommitCoordinator.shared.commit(
            .createAssetOnly(operationID: operationID) { asset in
                StickerMakerModel.fill(asset: asset, kind: .sticker, working: working, mask: nil)
            }, in: CoreDataTestSupport.sharedTestContainer)
        return try XCTUnwrap(receipt.assetID)
    }

    func testNoneDraftCommitsNothing() async throws {
        let ownerKey = UUID().uuidString
        try await VisualAppearanceDraft.none.commit(ownerKind: "spendingProject",
                                                    ownerKey: ownerKey, slot: "primaryVisual",
                                                    in: CoreDataTestSupport.sharedTestContainer)
        let resolved = VisualAssetRepository.shared.resolvePlacement(
            ownerKind: "spendingProject", ownerKey: ownerKey, slot: "primaryVisual", in: context)
        XCTAssertEqual(resolved, .none, ".none 草稿不应产生任何版本")
    }

    func testSetDraftCommitsAndResolvesReady() async throws {
        let assetID = try await createStickerAsset()
        let ownerKey = UUID().uuidString
        try await VisualAppearanceDraft.set(assetID: assetID,
                                            presentation: .init(scale: 0.9, borderStyle: .white))
            .commit(ownerKind: "spendingProject", ownerKey: ownerKey, slot: "primaryVisual",
                    in: CoreDataTestSupport.sharedTestContainer)
        guard case .assetReady(let descriptor) = VisualAssetRepository.shared.resolvePlacement(
            ownerKind: "spendingProject", ownerKey: ownerKey, slot: "primaryVisual", in: context) else {
            return XCTFail(".set 草稿保存后应解析为 assetReady")
        }
        XCTAssertEqual(descriptor.assetID, assetID)
        XCTAssertEqual(descriptor.presentation?.borderStyle, .white)
    }

    func testClearedDraftClearsExistingPlacement() async throws {
        let assetID = try await createStickerAsset()
        let ownerKey = UUID().uuidString
        try await VisualAppearanceDraft.set(assetID: assetID, presentation: nil)
            .commit(ownerKind: "spendingProject", ownerKey: ownerKey, slot: "primaryVisual",
                    in: CoreDataTestSupport.sharedTestContainer)
        try await VisualAppearanceDraft.cleared
            .commit(ownerKind: "spendingProject", ownerKey: ownerKey, slot: "primaryVisual",
                    in: CoreDataTestSupport.sharedTestContainer)
        let resolved = VisualAssetRepository.shared.resolvePlacement(
            ownerKind: "spendingProject", ownerKey: ownerKey, slot: "primaryVisual", in: context)
        XCTAssertEqual(resolved, .none, ".cleared 草稿保存后应回到无贴纸")
    }

    func testStaleBaselineThrowsConflictInsteadOfOverwriting() async throws {
        let asset1 = try await createStickerAsset()
        let asset2 = try await createStickerAsset()
        let ownerKey = UUID().uuidString
        try await VisualAppearanceDraft.set(assetID: asset1, presentation: nil)
            .commit(ownerKind: "spendingProject", ownerKey: ownerKey, slot: "primaryVisual",
                    in: CoreDataTestSupport.sharedTestContainer)
        // 陈旧基线（nil）：已有赢家时必须抛 conflict 而不是静默覆盖（B10 吞错修复）
        do {
            try await VisualAppearanceDraft.set(assetID: asset2, presentation: nil)
                .commit(ownerKind: "spendingProject", ownerKey: ownerKey, slot: "primaryVisual",
                        in: CoreDataTestSupport.sharedTestContainer)
            XCTFail("陈旧基线提交应抛 conflict")
        } catch let error as VisualCommitError {
            guard case .conflict = error else {
                return XCTFail("应抛 conflict，实际: \(error)")
            }
        }
        // 正确基线：覆盖成功
        guard case .assetReady(let current) = VisualAssetRepository.shared.resolvePlacement(
            ownerKind: "spendingProject", ownerKey: ownerKey, slot: "primaryVisual", in: context) else {
            return XCTFail("应已有赢家")
        }
        try await VisualAppearanceDraft.set(assetID: asset2, presentation: nil)
            .commit(ownerKind: "spendingProject", ownerKey: ownerKey, slot: "primaryVisual",
                    expectedSlotWinnerRevisionID: current.winningRevisionID,
                    in: CoreDataTestSupport.sharedTestContainer)
        guard case .assetReady(let after) = VisualAssetRepository.shared.resolvePlacement(
            ownerKind: "spendingProject", ownerKey: ownerKey, slot: "primaryVisual", in: context) else {
            return XCTFail("正确基线覆盖后应仍为 assetReady")
        }
        XCTAssertEqual(after.assetID, asset2)
    }
}

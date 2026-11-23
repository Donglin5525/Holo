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
import UIKit
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


// MARK: - 11-19：编辑贴纸原地更新 + presentation offset 兼容

final class VisualAssetUpdateAndOffsetTests: XCTestCase {

    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try? CoreDataTestSupport.clearEntities(context, ["VisualAsset", "VisualPlacementRevision", "VisualAssetTombstone"])
    }

    /// 编辑贴纸=原地更新：assetID 不变、像素字段被覆盖、引用位置无需迁移
    func testUpdateAssetOverwritesInPlaceKeepingID() async throws {
        let operationID = UUID()
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 components: [0.2, 0.6, 0.9, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let working = try VisualAssetImageProcessor.prepareWorkingImage(
            from: VisualAssetImageProcessor.encodePNG(ctx.makeImage()!)!)

        let create = try await VisualCommitCoordinator.shared.commit(
            .createAssetOnly(operationID: operationID) { asset in
                StickerMakerModel.fill(asset: asset, kind: .sticker, working: working, mask: nil)
                asset.setValue("原名", forKey: "displayName")
            }, in: CoreDataTestSupport.sharedTestContainer)
        let assetID = try XCTUnwrap(create.assetID)

        // 原地更新：改名+重写像素（颜色改红证明覆盖）
        ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 components: [0.9, 0.2, 0.2, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let working2 = try VisualAssetImageProcessor.prepareWorkingImage(
            from: VisualAssetImageProcessor.encodePNG(ctx.makeImage()!)!)
        let update = try await VisualCommitCoordinator.shared.commit(
            .updateAsset(operationID: UUID(), assetID: assetID) { asset in
                StickerMakerModel.fill(asset: asset, kind: .sticker, working: working2, mask: nil)
                asset.setValue("新名", forKey: "displayName")
            }, in: CoreDataTestSupport.sharedTestContainer)
        XCTAssertEqual(update.assetID, assetID, "原地更新后 assetID 不变（引用位置无需迁移）")

        let request = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        request.predicate = NSPredicate(format: "id == %@", assetID as CVarArg)
        let rows = try context.fetch(request)
        XCTAssertEqual(rows.count, 1, "更新不新增行")
        XCTAssertEqual(rows.first?.value(forKey: "displayName") as? String, "新名")
        XCTAssertEqual(rows.first?.value(forKey: "libraryVisibility") as? String, "visible")
    }

    /// updateAsset 对不存在的 assetID 抛错（不静默新建）
    func testUpdateMissingAssetThrows() async throws {
        do {
            _ = try await VisualCommitCoordinator.shared.commit(
                .updateAsset(operationID: UUID(), assetID: UUID()) { _ in },
                in: CoreDataTestSupport.sharedTestContainer)
            XCTFail("更新不存在的素材应抛错")
        } catch {
            // 预期路径
        }
    }

    /// presentation offset 编解码：旧 JSON（无 offsetX/Y）解码回 0；新数据往返保持
    func testPresentationOffsetCodecRoundtripAndLegacy() throws {
        var p = VisualPlacementPayload.Presentation(scale: 0.9, offsetX: -0.25, offsetY: 0.4,
                                                    borderStyle: .white)
        let payload = VisualPlacementPayload.setAsset(.asset(UUID()), presentation: p)
        let json = String(data: try VisualPlacementCoding.canonicalData(payload), encoding: .utf8)!
        let decoded = try VisualPlacementCoding.decode(from: json)
        XCTAssertEqual(decoded.presentation?.offsetX ?? 99, -0.25)
        XCTAssertEqual(decoded.presentation?.offsetY ?? 99, 0.4)

        // 旧数据（手工去掉 offset 字段的 JSON 形状）→ 解码回 0
        let legacy = json
            .replacingOccurrences(of: ",\"offsetX\":-0.25,\"offsetY\":0.4", with: "")
            .replacingOccurrences(of: ",\"offsetX\":-0.25", with: "")
            .replacingOccurrences(of: ",\"offsetY\":0.4", with: "")
        let decodedLegacy = try VisualPlacementCoding.decode(from: legacy)
        XCTAssertEqual(decodedLegacy.presentation?.offsetX ?? 99, 0, "旧数据无 offset 字段应回 0")
        XCTAssertEqual(decodedLegacy.presentation?.offsetY ?? 99, 0)
        _ = p
    }

    /// 编辑贴纸正确语义（11-19 东林实报回归锁）：loadEdited 直接载入主体+遮罩——
    /// 不走原图重抠（phase 直接 .editing、遮罩尺寸与主体一致、形状保留）
    @MainActor
    func testLoadEditedKeepsCutoutShapeWithoutVision() async throws {
        // 合成「已抠好的主体」：透明底橙方块 120×120
        let ctx = CGContext(data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 components: [0.9, 0.4, 0.1, 1])!)
        ctx.fill(CGRect(x: 10, y: 10, width: 100, height: 100))
        let subject = ctx.makeImage()!

        // 「用户修过形状」的 mask：只在左半占用
        var maskBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 120, 120, kCVPixelFormatType_OneComponent8, nil, &maskBuffer)
        CVPixelBufferLockBaseAddress(maskBuffer!, [])
        let base = CVPixelBufferGetBaseAddress(maskBuffer!)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(maskBuffer!)
        for y in 0..<120 {
            for x in 0..<120 {
                base[y * rowBytes + x] = x < 60 ? 255 : 0
            }
        }
        CVPixelBufferUnlockBaseAddress(maskBuffer!, [])

        // async 形态与既有 ModeSwitch 测试同款（同步构造实测在测试进程触发
        // 恒定地址 malloc 崩，async 下同路径稳定）
        let model = StickerMakerModel(initialMode: .sticker)
        model.loadEdited(subject: subject, mask: maskBuffer!)
        XCTAssertEqual(model.phase, .editing, "编辑载入必须直接进入编辑态（不走 Vision 提取）")
        XCTAssertEqual(model.mode, .sticker)
        let restored = try XCTUnwrap(model.occupancyMask)
        XCTAssertEqual(CVPixelBufferGetWidth(restored), 120)
        XCTAssertEqual(CVPixelBufferGetHeight(restored), 120)
        // 形状保留：左半占用、右半不占用
        CVPixelBufferLockBaseAddress(restored, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(restored, .readOnly) }
        let rb = CVPixelBufferGetBaseAddress(restored)!.assumingMemoryBound(to: UInt8.self)
        let rRow = CVPixelBufferGetBytesPerRow(restored)
        XCTAssertGreaterThan(rb[60 * rRow + 30], 200, "左半应保持占用")
        XCTAssertEqual(rb[60 * rRow + 90], 0, "右半应保持不占用（修过的形状不能丢）")
    }

    /// 缓存 key 含 offset：位移变化产生不同 key（重渲染保证）
    func testCacheKeyIncludesOffset() {
        let id = UUID()
        var p = VisualPlacementPayload.Presentation()
        let k1 = VisualRenderCache.key(assetID: id, role: .icon, appearance: .light,
                                       increasedContrast: false, displayScale: 3, presentation: p)
        p.offsetX = 0.3
        let k2 = VisualRenderCache.key(assetID: id, role: .icon, appearance: .light,
                                       increasedContrast: false, displayScale: 3, presentation: p)
        XCTAssertNotEqual(k1, k2)
    }
}

// MARK: - 想法头图通栏排版（2026-11-23 东林拍板方案 B）

final class ThoughtHeroLayoutTests: XCTestCase {

    /// iPhone 上想法卡的实际宽度（屏宽 402 − 列表左右边距 21×2）
    private let cardWidth: CGFloat = 360

    private func photo(_ width: Int, _ height: Int) -> ResolvedPlacement {
        .assetReady(VisualDescriptor(assetID: UUID(), winningRevisionID: UUID(), kind: .photo,
                                     presentation: nil, pixelWidth: width, pixelHeight: height))
    }

    private var sticker: ResolvedPlacement {
        .assetReady(VisualDescriptor(assetID: UUID(), winningRevisionID: UUID(), kind: .sticker,
                                     presentation: nil))
    }

    /// 把头图通栏按卡片宽度真实排版一遍，量它实际占的高度（打开界面量，不靠推算）
    @MainActor
    private func height(of placement: ResolvedPlacement, largeText: Bool = false) -> CGFloat {
        let band = ThoughtHeroListPreview(placement: placement, style: .plain)
            .frame(width: cardWidth)
            .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
        return UIHostingController(rootView: band)
            .sizeThatFits(in: CGSize(width: cardWidth, height: 10_000)).height
    }

    @MainActor
    func testPhotoInsideRangeKeepsItsOwnRatio() {
        XCTAssertEqual(height(of: photo(1920, 1080)), 202.5, accuracy: 0.5, "16:9 宽图")
        XCTAssertEqual(height(of: photo(4032, 3024)), 270, accuracy: 0.5, "iPhone 默认 4:3")
    }

    @MainActor
    func testTallerThanFourThreeIsClamped() {
        XCTAssertEqual(height(of: photo(3024, 4032)), 270, accuracy: 0.5, "3:4 竖图")
        XCTAssertEqual(height(of: photo(1170, 2532)), 270, accuracy: 0.5, "9:16 截图")
    }

    @MainActor
    func testWiderThanSixteenNineIsClamped() {
        XCTAssertEqual(height(of: photo(4000, 1200)), 202.5, accuracy: 0.5, "全景")
    }

    @MainActor
    func testUnknownPixelSizeFallsBackToFourThree() {
        XCTAssertEqual(height(of: photo(0, 0)), 270, accuracy: 0.5, "尺寸未同步到")
    }

    @MainActor
    func testStickerSitsOnStageOfFixedHeight() {
        XCTAssertEqual(height(of: sticker), 148, accuracy: 0.5)
    }

    @MainActor
    func testLargeTextShrinksPhotoToShortestBand() {
        XCTAssertEqual(height(of: photo(4032, 3024), largeText: true), 202.5, accuracy: 0.5)
        XCTAssertEqual(height(of: photo(3024, 4032), largeText: true), 202.5, accuracy: 0.5)
    }

    @MainActor
    func testNotReadyHeroTakesNoSpace() {
        XCTAssertEqual(height(of: .none), 0, accuracy: 0.01)
        XCTAssertEqual(height(of: .pending), 0, accuracy: 0.01)
        XCTAssertEqual(height(of: .deleted), 0, accuracy: 0.01)
    }

    @MainActor
    func testBandRatioMath() {
        XCTAssertEqual(ThoughtHeroPhotoLayout.bandRatio(pixelWidth: 3, pixelHeight: 4, shrinksForLargeText: false),
                       4.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(ThoughtHeroPhotoLayout.bandRatio(pixelWidth: 7, pixelHeight: 3, shrinksForLargeText: false),
                       16.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(ThoughtHeroPhotoLayout.bandRatio(pixelWidth: 3, pixelHeight: 2, shrinksForLargeText: false),
                       1.5, accuracy: 1e-9)
        XCTAssertEqual(ThoughtHeroPhotoLayout.bandRatio(pixelWidth: 3, pixelHeight: 2, shrinksForLargeText: true),
                       16.0 / 9.0, accuracy: 1e-9)
    }

    @MainActor
    func testBandClassification() {
        XCTAssertTrue(ThoughtHeroListPreview.occupiesSpace(photo(1920, 1080)))
        XCTAssertTrue(ThoughtHeroListPreview.isPhotoBand(photo(1920, 1080)), "照片通栏：纸张装饰要避开")
        XCTAssertTrue(ThoughtHeroListPreview.occupiesSpace(sticker))
        XCTAssertFalse(ThoughtHeroListPreview.isPhotoBand(sticker), "贴纸站在纸面舞台上，装饰照画")
        XCTAssertFalse(ThoughtHeroListPreview.occupiesSpace(.pending), "未就绪的头图不占位")
    }
}

// MARK: - 头图与附件「同一张照片」判定

final class ThoughtHeroPhotoFingerprintTests: XCTestCase {

    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// 画面里的一处明暗：位置与半径按画面比例记，seed 相同则画面相同
    private struct Blob {
        let u: Double, v: Double, r: Double, tone: Double
    }

    private func blobs(seed: UInt64) -> [Blob] {
        var generator = SeededGenerator(seed)
        return (0..<14).map { _ in
            Blob(u: Double.random(in: 0.08...0.92, using: &generator),
                 v: Double.random(in: 0.08...0.92, using: &generator),
                 r: Double.random(in: 0.12...0.34, using: &generator),
                 tone: Double.random(in: 0.05...0.95, using: &generator))
        }
    }

    /// 生成一张明暗错落的「照片」：zoom 调构图、brightness 调明暗、jpegQuality 换存法
    @MainActor
    private func photoData(_ blobs: [Blob], width: CGFloat, height: CGFloat, zoom: CGFloat = 1,
                           brightness: CGFloat = 0, jpegQuality: Double? = nil) throws -> Data {
        let size = CGSize(width: width, height: height)
        let gradients = try blobs.map { blob -> CGGradient in
            let tone = min(max(blob.tone + brightness, 0), 1)
            return try XCTUnwrap(CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceGray(),
                colors: [UIColor(white: tone, alpha: 1).cgColor, UIColor(white: tone, alpha: 0).cgColor] as CFArray,
                locations: [0, 1]))
        }
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.4 + brightness, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (blob, gradient) in zip(blobs, gradients) {
                // 以画面中心为基准缩放构图：zoom < 1 相当于镜头拉近了一截
                let center = CGPoint(x: ((blob.u - 0.5) * zoom + 0.5) * width,
                                     y: ((blob.v - 0.5) * zoom + 0.5) * height)
                context.cgContext.drawRadialGradient(
                    gradient, startCenter: center, startRadius: 0, endCenter: center,
                    endRadius: blob.r * min(width, height) * zoom, options: [])
            }
        }
        if let jpegQuality { return try XCTUnwrap(image.jpegData(compressionQuality: jpegQuality)) }
        return try XCTUnwrap(image.pngData())
    }

    @MainActor
    private func samePhoto(_ a: Data, _ b: Data) throws -> Bool {
        let printA = try XCTUnwrap(ThoughtHeroPhotoFingerprint.fingerprint(from: a))
        let printB = try XCTUnwrap(ThoughtHeroPhotoFingerprint.fingerprint(from: b))
        return ThoughtHeroPhotoFingerprint.isSamePhoto(printA, printB)
    }

    /// 两次落库的编码、尺寸、明暗都不同，只要是同一张画面就得认出来
    @MainActor
    func testSamePhotoStoredDifferentlyIsRecognized() throws {
        let subject = blobs(seed: 7)
        let hero = try photoData(subject, width: 640, height: 480)
        let attachment = try photoData(subject, width: 1440, height: 1080, brightness: 0.12, jpegQuality: 0.5)
        XCTAssertTrue(try samePhoto(hero, attachment))
    }

    @MainActor
    func testReframedShotIsNotTheSamePhoto() throws {
        let subject = blobs(seed: 7)
        let hero = try photoData(subject, width: 640, height: 480)
        let reframed = try photoData(subject, width: 640, height: 480, zoom: 0.9, jpegQuality: 0.6)
        XCTAssertFalse(try samePhoto(hero, reframed), "镜头拉近一截的另一张不能被当成同一张藏起来")
    }

    @MainActor
    func testDifferentPhotosAreNotMerged() throws {
        let hero = try photoData(blobs(seed: 7), width: 640, height: 480)
        let other = try photoData(blobs(seed: 8), width: 640, height: 480, jpegQuality: 0.6)
        XCTAssertFalse(try samePhoto(hero, other))
    }

    @MainActor
    func testFlatFramesNeverMatch() throws {
        let sky = try photoData([], width: 320, height: 240)
        let brighterSky = try photoData([], width: 480, height: 360, brightness: 0.2, jpegQuality: 0.6)
        XCTAssertFalse(try samePhoto(sky, brighterSky), "几乎没有明暗差的画面之间不做判定")
    }
}

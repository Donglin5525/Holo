//
//  GalleryVisualSupport.swift
//  Holo
//
//  长廊视觉投影接线（方案 04 §1/§2，原型场景五 1:1）：
//  时间线主预览优先展示想法头图（有头图 > 旧附件 > 文字），贴纸完整显示；
//  「找日期」升级图片月历——每天一张代表图 + N 条，日期/今天/选中标记始终在图片外。
//

import SwiftUI
import CoreData

extension CalendarEvent {
    /// 想法事件的头图位置（业务 UUID 关联；其他模块 nil）
    var heroVisualPlacement: ResolvedPlacement? {
        guard module == .thought else { return nil }
        // CalendarEvent.id 是非可选 UUID（值类型，无存量 nil 问题）
        return VisualAssetRepository.shared.resolvePlacement(
            ownerKind: Thought.visualOwnerKind,
            ownerKey: id.uuidString,
            slot: Thought.visualSlot,
            in: CoreDataStack.shared.viewContext)
    }
}

/// 时间线主预览的头图横幅：贴纸完整显示（纸感底），照片沿用裁切横幅
struct MemoryGalleryHeroBanner: View {
    let placement: ResolvedPlacement

    var body: some View {
        if case .assetReady(let descriptor) = placement {
            let isSticker = descriptor.kind == .sticker
            if isSticker {
                // 贴纸：完整显示 + 纸感浅底（不裁切、不加框抢形）
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.galleryInset)
                    VisualPlacementView(placement: .assetReady(descriptor), role: .list)
                        .padding(10)
                }
                .frame(height: 132)
                .padding(.bottom, 11)
            } else {
                // 照片头图：沿用附件横幅的定长槽位纪律
                if let data = heroPixelData(descriptor) {
                    MemoryGalleryCroppedBanner(data: data, ratio: 1.88, cornerRadius: 9)
                        .padding(.bottom, 11)
                }
            }
        }
    }

    private func heroPixelData(_ descriptor: VisualDescriptor) -> Data? {
        let request = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        request.predicate = NSPredicate(format: "id == %@", descriptor.assetID as CVarArg)
        request.fetchLimit = 1
        let asset = try? CoreDataStack.shared.viewContext.fetch(request).first
        return asset?.value(forKey: "thumbnailData") as? Data
    }
}

/// 找日期面板的图片模式格子（04 §3.2：日期/今天/选中在图外，数量「N 条」）
struct FindDateImageCell: View {
    let day: Int
    let isToday: Bool
    let isSelected: Bool
    let thumb: CGImage?
    let count: Int?

    var body: some View {
        VStack(spacing: 3) {
            Text("\(day)")
                .font(.system(size: 11.5, weight: isSelected ? .bold : .regular).monospacedDigit())
                .foregroundStyle(dayText)
                .padding(.horizontal, isToday ? 5 : 0)
                .background {
                    if isToday {
                        Capsule().fill(Color.galleryOrange)
                    }
                }
            Group {
                if let thumb {
                    Image(uiImage: UIImage(cgImage: thumb))
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.galleryInset)
                        if let count, count > 0 {
                            Circle().fill(Color.galleryOrange)
                                .frame(width: 4.5, height: 4.5)
                        }
                    }
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.galleryInk, lineWidth: 1.5)
                }
            }
            Text(count.map { "\($0) 条" } ?? "")
                .font(.system(size: 8.5))
                .foregroundStyle(Color.galleryQuiet)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .contentShape(Rectangle())
    }

    private var dayText: Color {
        isToday ? .white : Color.galleryInk
    }
}

extension VisualDescriptor {
    /// 月历缩略图：320px 派生直接解（P5 换成渲染缓存通道）
    func thumbnailPixel() -> CGImage? {
        let request = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        request.predicate = NSPredicate(format: "id == %@", assetID as CVarArg)
        request.fetchLimit = 1
        guard let asset = try? CoreDataStack.shared.viewContext.fetch(request).first,
              let data = asset.value(forKey: "thumbnailData") as? Data else { return nil }
        return VisualAssetImageProcessor.decodeWorkingCGImage(from: data)
    }
}

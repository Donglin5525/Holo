import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import Foundation

/// 只携带展示快照，异步图片仍由编辑器原来的上传/重试/删除链路处理。
struct ThoughtPaperPhotoSource: Identifiable {
    enum Status: Equatable { case ready, loading, failed }
    let id: UUID
    var image: UIImage? = nil
    var thumbnailData: Data? = nil
    var fileName: String? = nil
    var thoughtId: UUID? = nil
    var status: Status = .ready
}

struct ThoughtPaperPhotos: View {
    let sources: [ThoughtPaperPhotoSource]
    let style: ThoughtStyle
    let width: CGFloat
    var compact = false
    var onOpen: ((UUID) -> Void)? = nil
    var onRemove: ((UUID) -> Void)? = nil

    private var columns: Int { sources.count > 1 ? 2 : 1 }
    private var slot: CGFloat { max(1, (width - CGFloat(columns - 1) * HoloSpacing.md) / CGFloat(columns)) }

    var body: some View {
        if !sources.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HoloSpacing.md), count: columns), alignment: style == .bookmark ? .trailing : .leading, spacing: HoloSpacing.md) {
                ForEach(sources) { source in
                    ThoughtPaperPhotoCell(source: source, style: style, slotWidth: slot, compact: compact, onOpen: onOpen, onRemove: onRemove)
                        .frame(maxWidth: .infinity, alignment: style == .bookmark ? .trailing : .leading)
                }
            }
            .frame(width: max(1, width))
        }
    }
}

private struct ThoughtPaperPhotoCell: View {
    let source: ThoughtPaperPhotoSource
    let style: ThoughtStyle
    let slotWidth: CGFloat
    let compact: Bool
    let onOpen: ((UUID) -> Void)?
    let onRemove: ((UUID) -> Void)?
    @State private var decodedImage: UIImage?
    @State private var loadFailed = false

    private var loadKey: String { "\(source.id)|\(source.thumbnailData?.count ?? 0)|\(source.fileName ?? "")|\(source.image != nil)" }

    private var image: UIImage? { source.image ?? decodedImage ?? source.thumbnailData.flatMap(AttachmentImageLoader.cachedThumbnail(for:)) }
    private var width: CGFloat {
        slotWidth * (compact ? 1 : style == .bookmark ? 0.74 : style == .dots ? 0.66 : 1)
    }
    private var height: CGFloat {
        if style == .plain { return width }
        if compact { return min(ThoughtPaperMetrics.compactPhotoHeight, width * 0.7) }
        let ratio: CGFloat = style == .field || style == .bookmark ? 1.3 : style == .ticket ? 2.05 : style == .film ? 1.8 : style == .dots ? 1 : 1.6
        return width / ratio
    }

    var body: some View {
        interactivePhoto
            .overlay(alignment: .topTrailing) {
                if let onRemove {
                    Button { onRemove(source.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.holoToolText, Color.holoToolSurface)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "移除图片"))
                }
            }
            .task(id: loadKey) {
                guard source.image == nil else { return }
                loadFailed = false
                if let data = source.thumbnailData {
                    decodedImage = await AttachmentImageLoader.decodedThumbnail(from: data)
                } else if let file = source.fileName, let thoughtId = source.thoughtId {
                    decodedImage = await Task.detached(priority: .userInitiated) {
                        AttachmentFileManager.loadThumbnail(fileName: file, taskId: thoughtId)
                    }.value
                }
                loadFailed = decodedImage == nil
            }
    }

    @ViewBuilder
    private var interactivePhoto: some View {
        if let onOpen {
            Button { onOpen(source.id) } label: {
                photo.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(source.status == .failed ? String(localized: "图片加载失败，轻点重试") : String(localized: "查看图片"))
        } else {
            photo.accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "想法图片"))
        }
    }

    private var photo: some View {
        ZStack {
            if let image {
                #if canImport(UIKit)
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: max(1, width - (style == .film || style == .post ? 8 : 0)), height: max(1, height))
                    .clipped()
                #else
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: max(1, width - (style == .film || style == .post ? 8 : 0)), height: max(1, height))
                    .clipped()
                #endif
            } else {
                Rectangle().fill(style.listBorder.opacity(0.45))
            }
            if source.status == .loading || (image == nil && source.status == .ready && !loadFailed) {
                ProgressView()
            } else if source.status == .failed {
                Label(onOpen == nil ? String(localized: "图片未就绪") : String(localized: "重试"), systemImage: "exclamationmark.triangle.fill")
                    .font(.holoLabel)
                    .foregroundStyle(Color.holoToolError)
                    .padding(HoloSpacing.sm)
                    .background(Color.holoToolSurface, in: Capsule())
            } else if loadFailed && image == nil {
                Label(String(localized: "图片暂不可用"), systemImage: "photo")
                    .font(.holoLabel)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
        }
        .frame(width: max(1, width - (style == .post ? 8 : 0)), height: height)
        .background(style == .film ? style.ink : style.paper)
        .clipped()
        .padding(style == .post ? HoloSpacing.xs : 0)
        .padding(.bottom, style == .post ? HoloSpacing.sm : 0)
        .background(style.paper)
        .overlay {
            if style == .post { Rectangle().stroke(style.listBorder, lineWidth: 0.5) }
        }
    }
}

/// 编辑器的照片叶子组件：原样保留横向缩略条，模板把照片纳入纸面构图。
struct ThoughtEditorPaperPhotos: View {
    let sources: [ThoughtPaperPhotoSource]
    let style: ThoughtStyle
    let onOpen: (UUID) -> Void
    let onRemove: (UUID) -> Void
    @State private var availableWidth: CGFloat = 1

    var body: some View {
        Group {
            if !sources.isEmpty {
                if style == .plain {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: HoloSpacing.md) {
                            ForEach(sources) { source in
                                ThoughtPaperPhotos(sources: [source], style: .plain, width: 80, compact: true, onOpen: onOpen, onRemove: onRemove)
                            }
                        }
                    }
                    .padding(HoloSpacing.md)
                } else {
                    ThoughtPaperPhotos(sources: sources, style: style, width: availableWidth, onOpen: onOpen, onRemove: onRemove)
                        .padding(.leading, style.textInset)
                        .padding(.trailing, style.trailingInset)
                        .padding(.vertical, HoloSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            max(1, proxy.size.width - style.textInset - style.trailingInset)
                        } action: { availableWidth = $0 }
                }
            }
        }
    }
}

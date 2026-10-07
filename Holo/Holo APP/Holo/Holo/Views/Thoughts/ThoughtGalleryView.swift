//
//  ThoughtGalleryView.swift
//  Holo
//
//  想法附件全屏图片浏览器 — 横向滑动、双指缩放、页码指示
//
//  性能口径（多图卡顿专项）：缩略图先行上屏（后台通道秒出 300px），原图解码
//  完成后替换；只保证当前页与左右邻页——此前打开即主线程逐张读 5 个大二进制、
//  并发全量解码 N 张 2048px 位图（约 80MB 内存）且无缓存的历史不再重演。
//

import SwiftUI
import CoreData

struct ThoughtGalleryView: View {
    let attachments: [ThoughtAttachment]
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var thumbnails: [UIImage?]
    @State private var fullImages: [UIImage?]

    init(attachments: [ThoughtAttachment], startIndex: Int) {
        self.attachments = attachments
        self.startIndex = startIndex
        self._currentIndex = State(initialValue: startIndex)
        self._thumbnails = State(initialValue: Array(repeating: nil, count: attachments.count))
        self._fullImages = State(initialValue: Array(repeating: nil, count: attachments.count))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部关闭按钮
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // 图片区域
                TabView(selection: $currentIndex) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { index, _ in
                        ZoomableImageView(
                            image: pageImage(index),
                            isLoading: pageImage(index) == nil,
                            onSingleTap: { dismiss() }
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // 页码指示器
                Text("\(currentIndex + 1)/\(attachments.count)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.bottom, 40)
            }
        }
        // 全屏图库阅读页：边缘右滑返回（fullScreenCover 无系统返回；左缘与翻页手势共存）
        .holoEdgeSwipeBack { dismiss() }
        .task {
            await ensurePages(around: startIndex)
        }
        .onChange(of: currentIndex) { _, newIndex in
            Task { await ensurePages(around: newIndex) }
        }
    }

    // MARK: - 按页加载

    /// 两轮加载：先把窗口内三页的缩略图全部点亮（快），再逐页补原图（慢）。
    private func ensurePages(around index: Int) async {
        let window = [index, index + 1, index - 1]
        for i in window {
            guard attachments.indices.contains(i), thumbnails[i] == nil else { continue }
            let objectID = attachments[i].objectID
            if let fromBlob = await AttachmentImageLoader.thumbnail(objectID: objectID) {
                thumbnails[i] = fromBlob
            } else {
                thumbnails[i] = await legacyThumbnail(i)
            }
        }
        for i in window {
            guard attachments.indices.contains(i), fullImages[i] == nil else { continue }
            let objectID = attachments[i].objectID
            if let fromBlob = await AttachmentImageLoader.fullImage(objectID: objectID) {
                fullImages[i] = fromBlob
            } else {
                fullImages[i] = await legacyFull(i)
            }
        }
    }

    private func pageImage(_ index: Int) -> UIImage? {
        guard fullImages.indices.contains(index) else { return nil }
        return fullImages[index] ?? thumbnails[index]
    }

    /// 旧附件回退（1.0 早期磁盘版，CoreData 无二进制）：只有 blob 通道落空
    /// 才读文件名（fire 附件行）——新附件 blob 必有，主线程不碰附件行。
    private func legacyThumbnail(_ index: Int) async -> UIImage? {
        let attachment = attachments[index]
        let owner = attachment.thought?.id ?? attachment.id
        return await AttachmentImageLoader.thumbnail(
            objectID: attachment.objectID,
            fallbackFileName: attachment.thumbnailFileName,
            ownerID: owner
        )
    }

    private func legacyFull(_ index: Int) async -> UIImage? {
        let attachment = attachments[index]
        let owner = attachment.thought?.id ?? attachment.id
        return await AttachmentImageLoader.fullImage(
            objectID: attachment.objectID,
            fallbackFileName: attachment.fileName,
            ownerID: owner
        )
    }
}

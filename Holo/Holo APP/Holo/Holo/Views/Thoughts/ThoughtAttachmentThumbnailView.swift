//
//  ThoughtAttachmentThumbnailView.swift
//  Holo
//
//  想法附件缩略图视图 — 异步加载，1:1 正方形裁剪
//
//  解码走 AttachmentImageLoader 共享缓存（此前主线程同步 UIImage(data:)，
//  惰性解码落在首帧渲染；且无缓存，列表滚动回收复用即重复解码）。
//

import SwiftUI

struct ThoughtAttachmentThumbnailView: View {
    let thumbnailData: Data?
    let fileName: String
    let thoughtId: UUID

    @State private var image: UIImage?

    /// body 内联同步探测共享缓存：滚动回位当帧命中，不闪占位图
    private var resolvedImage: UIImage? {
        if let image { return image }
        guard let thumbnailData else { return nil }
        return AttachmentImageLoader.cachedThumbnail(for: thumbnailData)
    }

    var body: some View {
        Group {
            if let resolvedImage {
                Image(uiImage: resolvedImage)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            } else {
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .fill(Color.holoBackground)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(ProgressView())
            }
        }
        .task {
            guard resolvedImage == nil else { return }
            // 优先从 CoreData 二进制数据加载
            if let thumbnailData {
                image = await AttachmentImageLoader.decodedThumbnail(from: thumbnailData)
                return
            }
            // 回退到文件系统（旧附件）
            image = await Task.detached(priority: .userInitiated) {
                AttachmentFileManager.loadThumbnail(fileName: fileName, taskId: thoughtId)
            }.value
        }
    }
}

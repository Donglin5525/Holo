//
//  AttachmentThumbnailView.swift
//  Holo
//
//  附件缩略图视图 — 1:1 正方形裁剪，异步加载缩略图
//

import SwiftUI

struct AttachmentThumbnailView: View {
    let fileName: String
    let taskId: UUID
    let thumbnailData: Data?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.holoCardBackground
                    .overlay(
                        ProgressView()
                            .tint(.holoTextSecondary)
                    )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        .task {
            // 优先从 CoreData 二进制数据加载（新附件），回退到文件系统（旧附件）
            if let thumbnailData {
                image = UIImage(data: thumbnailData)
            } else {
                image = AttachmentFileManager.loadThumbnail(fileName: fileName, taskId: taskId)
            }
        }
    }
}

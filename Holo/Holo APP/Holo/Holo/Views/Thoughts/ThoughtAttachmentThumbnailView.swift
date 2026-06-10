//
//  ThoughtAttachmentThumbnailView.swift
//  Holo
//
//  想法附件缩略图视图 — 异步加载，1:1 正方形裁剪
//

import SwiftUI

struct ThoughtAttachmentThumbnailView: View {
    let thumbnailData: Data?
    let fileName: String
    let thoughtId: UUID

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
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
            guard image == nil else { return }
            // 优先从 CoreData 二进制数据加载
            if let thumbnailData {
                image = UIImage(data: thumbnailData)
                return
            }
            // 回退到文件系统
            image = AttachmentFileManager.loadThumbnail(
                fileName: fileName,
                taskId: thoughtId
            )
        }
    }
}

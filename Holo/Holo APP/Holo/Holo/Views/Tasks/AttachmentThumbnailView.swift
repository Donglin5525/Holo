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
            image = AttachmentFileManager.loadThumbnail(fileName: fileName, taskId: taskId)
        }
    }
}

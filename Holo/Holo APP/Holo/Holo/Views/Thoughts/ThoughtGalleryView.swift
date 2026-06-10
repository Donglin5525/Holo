//
//  ThoughtGalleryView.swift
//  Holo
//
//  想法附件全屏图片浏览器 — 横向滑动、双指缩放、页码指示
//

import SwiftUI

struct ThoughtGalleryView: View {
    let attachments: [ThoughtAttachment]
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var images: [UIImage?] = []

    init(attachments: [ThoughtAttachment], startIndex: Int) {
        self.attachments = attachments
        self.startIndex = startIndex
        self._currentIndex = State(initialValue: startIndex)
        self._images = State(initialValue: Array(repeating: nil, count: attachments.count))
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
                            image: images[index],
                            isLoading: images[index] == nil,
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
        .task {
            loadAllImages()
        }
    }

    private func loadAllImages() {
        for (index, attachment) in attachments.enumerated() {
            // 优先从 CoreData 二进制数据加载（iCloud 同步后可用）
            if let imageData = attachment.imageData {
                if index < images.count {
                    images[index] = UIImage(data: imageData)
                }
                continue
            }
            // 回退到文件系统（旧附件）
            DispatchQueue.global(qos: .userInitiated).async {
                let thoughtId = attachment.thought?.id ?? attachment.id
                let image = AttachmentFileManager.loadFullImage(
                    fileName: attachment.fileName,
                    taskId: thoughtId
                )
                DispatchQueue.main.async {
                    if index < images.count {
                        images[index] = image
                    }
                }
            }
        }
    }
}

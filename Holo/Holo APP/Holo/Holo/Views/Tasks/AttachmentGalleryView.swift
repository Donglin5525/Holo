//
//  AttachmentGalleryView.swift
//  Holo
//
//  全屏图片浏览器 — 横向滑动、双指缩放、页码指示
//

import SwiftUI

struct AttachmentGalleryView: View {
    let attachments: [TaskAttachment]
    let startIndex: Int
    let taskId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var images: [UIImage?] = []

    init(attachments: [TaskAttachment], startIndex: Int, taskId: UUID) {
        self.attachments = attachments
        self.startIndex = startIndex
        self.taskId = taskId
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
        // 全屏图库阅读页：边缘右滑返回（fullScreenCover 无系统返回；左缘与翻页手势共存）
        .holoEdgeSwipeBack { dismiss() }
        .task {
            loadAllImages()
        }
    }

    private func loadAllImages() {
        for (index, attachment) in attachments.enumerated() {
            // 优先从 CoreData 二进制数据加载（新附件，iCloud 同步后可用）
            if let imageData = attachment.imageData {
                if index < images.count {
                    images[index] = UIImage(data: imageData)
                }
                continue
            }
            // 回退到文件系统（旧附件）
            DispatchQueue.global(qos: .userInitiated).async {
                let image = AttachmentFileManager.loadFullImage(
                    fileName: attachment.fileName,
                    taskId: taskId
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

// MARK: - 可缩放图片视图（基于 UIScrollView，未缩放时手势穿透给 TabView）

struct ZoomableImageView: View {
    let image: UIImage?
    let isLoading: Bool
    var onSingleTap: (() -> Void)? = nil

    var body: some View {
        ZStack {
            if let image {
                ZoomableScrollView(image: image)
            }
            if isLoading {
                ProgressView()
                    .tint(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // 双击：消费掉，不触发单击 dismiss，让 UIKit 层处理缩放
        }
        .onTapGesture(count: 1) {
            onSingleTap?()
        }
    }
}

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
                    ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                        ZoomableImageView(
                            image: images[index],
                            isLoading: images[index] == nil
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

// MARK: - 可缩放图片视图

struct ZoomableImageView: View {
    let image: UIImage?
    let isLoading: Bool

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let newScale = lastScale * value.magnification
                            scale = min(max(newScale, 1.0), 5.0)
                        }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1.0 {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            if scale > 1.0 {
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if scale > 1.0 {
                            scale = 1.0
                            lastScale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2.5
                            lastScale = 2.5
                        }
                    }
                }
        } else {
            ProgressView()
                .tint(.white)
        }
    }
}

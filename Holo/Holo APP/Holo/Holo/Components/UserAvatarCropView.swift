//
//  UserAvatarCropView.swift
//  Holo
//
//  圆形头像裁剪器：拖动定位、双指缩放，并预览三个真实使用尺寸。
//

import SwiftUI
import UIKit

struct UserAvatarCropView: View {

    let preparedData: Data
    let isProcessing: Bool
    let onCancel: () -> Void
    let onConfirm: (UserAvatarCropSelection) -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var viewportSide: CGFloat = 1
    @GestureState private var gestureZoom: CGFloat = 1
    @GestureState private var gestureOffset: CGSize = .zero

    private var image: UIImage? { UIImage(data: preparedData) }

    var body: some View {
        NavigationStack {
            VStack(spacing: HoloSpacing.xl) {
                Text("拖动照片调整位置，双指缩放")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)

                if let image {
                    GeometryReader { geometry in
                        let side = min(geometry.size.width, geometry.size.height)
                        cropCanvas(image: image, side: side)
                            .frame(width: side, height: side)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            .onAppear { viewportSide = side }
                            .onChange(of: side) { _, newValue in viewportSide = newValue }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 440)
                    .padding(.horizontal, HoloSpacing.md)

                    previewRow(image: image)
                } else {
                    ContentUnavailableView("无法读取图片", systemImage: "photo.badge.exclamationmark")
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, HoloSpacing.lg)
            .background(Color.holoBackground.ignoresSafeArea())
            .overlay {
                if isProcessing {
                    ZStack {
                        Color.black.opacity(0.16).ignoresSafeArea()
                        ProgressView("正在保存头像…")
                            .padding(.horizontal, HoloSpacing.xl)
                            .padding(.vertical, HoloSpacing.lg)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HoloRadius.lg))
                    }
                }
            }
            .allowsHitTesting(!isProcessing)
            .navigationTitle("裁剪头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .disabled(isProcessing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用") {
                        guard let image else { return }
                        onConfirm(selection(for: image, viewportSide: viewportSide))
                    }
                    .fontWeight(.semibold)
                    .disabled(image == nil || isProcessing)
                }
            }
        }
    }

    private func cropCanvas(image: UIImage, side: CGFloat) -> some View {
        let effectiveZoom = UserAvatarCropGeometry.clampedZoom(zoom * gestureZoom)
        let proposedOffset = CGSize(
            width: offset.width + gestureOffset.width,
            height: offset.height + gestureOffset.height
        )
        let effectiveOffset = UserAvatarCropGeometry.clampedOffset(
            proposedOffset,
            imageSize: image.size,
            viewportSide: side,
            zoom: effectiveZoom
        )
        let displayed = UserAvatarCropGeometry.displayedSize(
            imageSize: image.size,
            viewportSide: side,
            zoom: effectiveZoom
        )

        return ZStack {
            Image(uiImage: image)
                .resizable()
                .frame(width: displayed.width, height: displayed.height)
                .offset(effectiveOffset)

            UserAvatarCropMask()
                .fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true))

            Circle()
                .stroke(Color.white.opacity(0.92), lineWidth: 2)
                .padding(1)
        }
        .frame(width: side, height: side)
        .clipped()
        .contentShape(Rectangle())
        .gesture(dragGesture(image: image, side: side))
        .simultaneousGesture(magnificationGesture(image: image, side: side))
        .accessibilityLabel("头像裁剪区域")
        .accessibilityHint("拖动调整位置，双指缩放图片")
    }

    private func dragGesture(image: UIImage, side: CGFloat) -> some Gesture {
        DragGesture()
            .updating($gestureOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                offset = UserAvatarCropGeometry.clampedOffset(
                    CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height),
                    imageSize: image.size,
                    viewportSide: side,
                    zoom: zoom
                )
            }
    }

    private func magnificationGesture(image: UIImage, side: CGFloat) -> some Gesture {
        MagnificationGesture()
            .updating($gestureZoom) { value, state, _ in
                state = value
            }
            .onEnded { value in
                zoom = UserAvatarCropGeometry.clampedZoom(zoom * value)
                offset = UserAvatarCropGeometry.clampedOffset(
                    offset,
                    imageSize: image.size,
                    viewportSide: side,
                    zoom: zoom
                )
            }
    }

    private func selection(for image: UIImage, viewportSide: CGFloat) -> UserAvatarCropSelection {
        UserAvatarCropGeometry.selection(
            imageSize: image.size,
            viewportSide: viewportSide,
            zoom: zoom,
            offset: offset
        )
    }

    private func previewRow(image: UIImage) -> some View {
        HStack(alignment: .bottom, spacing: HoloSpacing.xl) {
            preview(image: image, size: 32, label: "对话")
            preview(image: image, size: 56, label: "账号")
            preview(image: image, size: 80, label: "个人")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("头像效果预览")
    }

    private func preview(image: UIImage, size: CGFloat, label: String) -> some View {
        VStack(spacing: HoloSpacing.xs) {
            UserAvatarCropPreview(
                image: image,
                selection: selection(for: image, viewportSide: viewportSide)
            )
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.holoBorder, lineWidth: 1))

            Text(label)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }
}

private struct UserAvatarCropPreview: View {
    let image: UIImage
    let selection: UserAvatarCropSelection

    var body: some View {
        GeometryReader { geometry in
            let rect = selection.normalizedRect
            let width = geometry.size.width / max(rect.width, 0.0001)
            let height = geometry.size.height / max(rect.height, 0.0001)
            Image(uiImage: image)
                .resizable()
                .frame(width: width, height: height)
                .position(
                    x: geometry.size.width / 2 + (0.5 - rect.midX) * width,
                    y: geometry.size.height / 2 + (0.5 - rect.midY) * height
                )
        }
        .clipped()
    }
}

private struct UserAvatarCropMask: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addEllipse(in: rect.insetBy(dx: 1, dy: 1))
        return path
    }
}

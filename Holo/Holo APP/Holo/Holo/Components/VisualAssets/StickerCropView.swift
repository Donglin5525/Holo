//
//  StickerCropView.swift
//  Holo
//
//  「重新裁剪」（方案 01 §3.3：回到原图，缩小画面范围后重新识别）：
//  原图上四角可拖的裁剪框，确认后返回归一化矩形，由制作页裁剪重建工作图并重新提取。
//  取景框只是构图提示的延伸——这里给用户精确的范围控制权。
//

import SwiftUI

struct StickerCropView: View {
    /// 原图（方向已摆正的工作图）
    let image: CGImage
    let onCancel: () -> Void
    /// 确认：返回归一化裁剪矩形（0...1，原点左上）
    let onConfirm: (CGRect) -> Void

    @State private var box: CGRect = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
    @State private var fitted: CGRect = .zero

    private enum Handle: String, CaseIterable {
        case topLeft = "top.leading", topRight = "top.trailing"
        case bottomLeft = "bottom.leading", bottomRight = "bottom.trailing"
    }

    var body: some View {
        HoloSheetScaffold(title: String(localized: "重新裁剪"),
                          onClose: onCancel,
                          primaryTitle: String(localized: "重新识别"),
                          primaryHint: String(localized: "裁小一点，主体更突出更容易识别")) {
            GeometryReader { geo in
                let fit = fitRect(in: geo.size)
                ZStack {
                    Image(uiImage: UIImage(cgImage: image))
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                    // 暗幕挖孔：非选中区压暗，选中区清晰
                    CropHoleShape(box: denormalized(in: fit))
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    // 裁剪框
                    cropBox(in: fit)
                }
                .onAppear { fitted = fit }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - 布局

    private func fitRect(in size: CGSize) -> CGRect {
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale
        let h = CGFloat(image.height) * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func denormalized(in fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + box.minX * fit.width,
               y: fit.minY + box.minY * fit.height,
               width: box.width * fit.width,
               height: box.height * fit.height)
    }

    private func cropBox(in fit: CGRect) -> some View {
        let rect = denormalized(in: fit)
        return ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            ForEach(Handle.allCases, id: \.self) { handle in
                handleView(handle, in: fit)
            }
        }
        .allowsHitTesting(false)
    }

    private func handleView(_ handle: Handle, in fit: CGRect) -> some View {
        let rect = denormalized(in: fit)
        let point: CGPoint
        switch handle {
        case .topLeft: point = CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: point = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: point = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: point = CGPoint(x: rect.maxX, y: rect.maxY)
        }
        return Circle()
            .fill(Color.white)
            .frame(width: 22, height: 22)
            .overlay { Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.black.opacity(0.6)) }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragHandle(handle, to: clampToLocal(value.location, in: fit))
                    }
            )
    }

    private func clampToLocal(_ point: CGPoint, in fit: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, fit.minX), fit.maxX),
                y: min(max(point.y, fit.minY), fit.maxY))
    }

    private func dragHandle(_ handle: Handle, to point: CGPoint) {
        // 图像坐标 → 归一化
        let minSide: CGFloat = 0.15
        let nx = min(max((point.x - fitted.minX) / max(fitted.width, 1), 0), 1)
        let ny = min(max((point.y - fitted.minY) / max(fitted.height, 1), 0), 1)
        var b = box
        switch handle {
        case .topLeft:
            b.origin.x = min(nx, b.maxX - minSide); b.origin.y = min(ny, b.maxY - minSide)
        case .topRight:
            b.size.width = max(nx - b.minX, minSide); b.origin.y = min(ny, b.maxY - minSide)
        case .bottomLeft:
            b.origin.x = min(nx, b.maxX - minSide); b.size.height = max(ny - b.minY, minSide)
        case .bottomRight:
            b.size.width = max(nx - b.minX, minSide); b.size.height = max(ny - b.minY, minSide)
        }
        box = b
    }
}

/// 暗幕挖孔形状（裁剪区外压暗，配 eoFill 挖孔）
struct CropHoleShape: Shape {
    let box: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRect(box)
        return path
    }
}

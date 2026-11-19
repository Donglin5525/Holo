//
//  StickerCropView.swift
//  Holo
//
//  「重新裁剪」（方案 01 §3.3；2026-11-18 手势热区根治 + 栈内 push 化）：
//  原图上四角可拖的裁剪框，确认后返回归一化矩形，由确认页裁剪重建工作图并重新提取。
//  - 手势必须挂在 .position 之前：position 修饰后的视图 frame=整个画布提案空间，
//    手柄/平移的手势热区会被撑满全画布、互相抢占（B7 根因）
//  - 画布用命名坐标系，拖动坐标显式锚定画布空间
//

import SwiftUI

struct StickerCropView: View {
    /// 原图（方向已摆正的工作图）
    let image: CGImage
    /// 右上角确认按钮文案（贴纸模式=「重新识别」，照片模式=「完成裁剪」）
    var confirmTitle: String = String(localized: "重新识别")
    /// 确认：返回归一化裁剪矩形（0...1，原点左上）
    let onConfirm: (CGRect) -> Void
    /// 取消/系统返回：无状态副作用，直接退出
    var onCancel: (() -> Void)? = nil

    @State private var box: CGRect = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
    @State private var panStartBox: CGRect?
    @Environment(\.dismiss) private var dismiss

    private static let canvasSpace = "stickerCropCanvas"

    private enum Handle: String, CaseIterable {
        case topLeft = "top.leading", topRight = "top.trailing"
        case bottomLeft = "bottom.leading", bottomRight = "bottom.trailing"
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                let fit = fitRect(in: geo.size)
                let rect = denormalized(in: fit)
                ZStack {
                    Image(uiImage: UIImage(cgImage: image))
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                    // 暗幕挖孔：非选中区压暗，选中区清晰
                    CropHoleShape(box: rect)
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    // 框内拖动平移（手势在 position 之前——热区=裁剪框本身，不吞四角）
                    Color.clear
                        .frame(width: rect.width, height: rect.height)
                        .contentShape(Rectangle())
                        .gesture(panGesture(in: fit))
                        .position(x: rect.midX, y: rect.midY)
                    // 裁剪框描边与九宫格参考线（不拦截触摸）
                    ZStack {
                        CropGridShape()
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.7)
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white, lineWidth: 1.5)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                    // 四角手柄（手势在 position 之前：各自只响应 44×44 热区）
                    ForEach(Handle.allCases, id: \.self) { handle in
                        handleView(handle, in: fit)
                    }
                }
                .coordinateSpace(name: Self.canvasSpace)
            }
            Text(String(localized: "拖动四角或框内调整裁剪范围"))
                .font(.system(size: 11.5))
                .foregroundColor(.holoToolTextSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.holoToolBackground)
        .navigationTitle(String(localized: "重新裁剪"))
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "取消")) { onCancel?(); dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(confirmTitle) { onConfirm(box) }
                    .font(.system(size: 14, weight: .semibold))
            }
        }
    }

    // MARK: - 手势

    private func panGesture(in fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                let start = panStartBox ?? box
                if panStartBox == nil { panStartBox = start }
                let dx = value.translation.width / max(fit.width, 1)
                let dy = value.translation.height / max(fit.height, 1)
                var next = start
                next.origin.x = min(max(start.origin.x + dx, 0), 1 - start.width)
                next.origin.y = min(max(start.origin.y + dy, 0), 1 - start.height)
                box = next
            }
            .onEnded { _ in panStartBox = nil }
    }

    private func handleGesture(_ handle: Handle, in fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                dragHandle(handle, to: clampToLocal(value.location, in: fit), in: fit)
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
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .frame(width: 24, height: 24)
            .overlay { Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.black.opacity(0.65)) }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(handleGesture(handle, in: fit))
            .position(point)
    }

    private func clampToLocal(_ point: CGPoint, in fit: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, fit.minX), fit.maxX),
                y: min(max(point.y, fit.minY), fit.maxY))
    }

    private func dragHandle(_ handle: Handle, to point: CGPoint, in fit: CGRect) {
        // 图像坐标 → 归一化；固定对角边，确保只移动被拖动的角
        let minSide: CGFloat = 0.12
        let nx = min(max((point.x - fit.minX) / max(fit.width, 1), 0), 1)
        let ny = min(max((point.y - fit.minY) / max(fit.height, 1), 0), 1)
        var minX = box.minX, maxX = box.maxX
        var minY = box.minY, maxY = box.maxY
        switch handle {
        case .topLeft:
            minX = min(nx, maxX - minSide)
            minY = min(ny, maxY - minSide)
        case .topRight:
            maxX = max(nx, minX + minSide)
            minY = min(ny, maxY - minSide)
        case .bottomLeft:
            minX = min(nx, maxX - minSide)
            maxY = max(ny, minY + minSide)
        case .bottomRight:
            maxX = max(nx, minX + minSide)
            maxY = max(ny, minY + minSide)
        }
        box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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

/// 裁剪框三等分九宫格参考线
private struct CropGridShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * CGFloat(i) / 3
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

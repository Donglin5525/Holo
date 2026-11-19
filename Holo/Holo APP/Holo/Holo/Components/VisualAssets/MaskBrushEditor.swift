//
//  MaskBrushEditor.swift
//  Holo
//
//  「修边」（方案 01 §3.3 / 02 §3.3；2026-11-18 性能根治 + 栈内 push 化）：
//  擦除多余区域、恢复被去掉区域、撤销、重置。
//  - 拖动中只画半透明实时轨迹，严禁调预览合成（B6 根治：拖动零卡死）
//  - 松手/撤销/重置后各在后台异步重算一次 ≤960px 预览（cachedPreview）
//  - 归一化几何用进入时的图像像素尺寸（imagePixelSize），不再依赖预览 provider
//  - 取消 = 回滚进入前的遮罩/笔画快照（由确认页 model.restoreMaskSession 收口）
//

import SwiftUI

struct MaskBrushEditor: View {
    /// 归一化几何真源：工作图像素尺寸（mask 与工作图同尺寸）
    let imagePixelSize: CGSize
    /// 原图参考底图（垫在抠图下方，避免「恢复误删」时盲涂）
    var originalImage: CGImage? = nil
    /// 异步重算预览：进入时一次 + 松手/撤销/重置后各一次
    let refreshPreview: () async -> CGImage?
    let onStroke: (_ points: [CGPoint], _ erase: Bool, _ brush: CGFloat) -> Void
    let onUndo: () -> Void
    let onReset: () -> Void
    let onDone: () -> Void
    /// 取消：调用方负责回滚进入前快照
    let onCancel: () -> Void

    @State private var eraseMode = true
    @State private var brush: CGFloat = 0.06      // 归一化直径（相对画布宽）
    @State private var canUndo = false
    @State private var cachedPreview: CGImage?
    @State private var showResetConfirm = false
    /// 双指缩放画布倍率（1.0~3.5x，放大后修边缘更精准）
    @State private var zoomScale: CGFloat = 1.0
    @State private var zoomBase: CGFloat = 1.0

    /// 本次会话的笔画计数（驱动 canUndo；真源 undo 在 Model）
    @State private var strokeCount = 0
    /// 拖动中暂存当前笔画（归一化坐标），松手一次性提交（避免逐像素入撤销栈与拖动卡顿）
    @State private var activeStrokePoints: [CGPoint] = []

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.holoToolInset)
                    ZStack {
                        // 原图弱透明底图：恢复误删时 38% 可清晰看清轮廓，擦除时 20% 作边界参照
                        if let originalImage {
                            Image(uiImage: UIImage(cgImage: originalImage))
                                .resizable()
                                .interpolation(.medium)
                                .aspectRatio(contentMode: .fit)
                                .padding(10)
                                .opacity(eraseMode ? 0.20 : 0.38)
                        }
                        if let cachedPreview {
                            Image(uiImage: UIImage(cgImage: cachedPreview))
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .padding(10)
                        }
                        if !activeStrokePoints.isEmpty {
                            liveStrokeOverlay(canvasSize: geo.size)
                                .allowsHitTesting(false)
                        }
                    }
                    .scaleEffect(zoomScale)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topTrailing) {
                    if zoomScale > 1.02 {
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                zoomScale = 1.0
                                zoomBase = 1.0
                            }
                        } label: {
                            Text("\(Int((zoomScale * 100).rounded()))% · 复位")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundColor(.holoToolText)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // 拖动中只更新轨迹，零合成；将屏幕点逆变换回未缩放画布坐标
                            let unscaled = unscalePoint(value.location, in: geo.size)
                            let p = normalize(unscaled, in: geo.size)
                            activeStrokePoints.append(p)
                        }
                        .onEnded { _ in
                            guard !activeStrokePoints.isEmpty else { return }
                            onStroke(activeStrokePoints, eraseMode, brush / zoomScale)
                            activeStrokePoints.removeAll()
                            strokeCount += 1
                            canUndo = true
                            recomputePreview()
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            // 双指缩放时取消误触发的单指暂存轨迹
                            if !activeStrokePoints.isEmpty { activeStrokePoints.removeAll() }
                            zoomScale = min(max(zoomBase * value, 1.0), 3.5)
                        }
                        .onEnded { _ in
                            zoomBase = zoomScale
                        }
                )
            }
            .frame(height: 350)
            .padding(.horizontal, 20)

            // 工具条
            VStack(spacing: 10) {
                Picker(String(localized: "工具"), selection: Binding(
                    get: { eraseMode }, set: { eraseMode = $0 })) {
                    Text(String(localized: "擦除多余")).tag(true)
                    Text(String(localized: "恢复误删")).tag(false)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 10) {
                    brushOption(label: String(localized: "细"), value: 0.035)
                    brushOption(label: String(localized: "中"), value: 0.06)
                    brushOption(label: String(localized: "粗"), value: 0.10)
                    Spacer()
                    Button {
                        guard strokeCount > 0 else { return }
                        onUndo()
                        strokeCount -= 1
                        canUndo = strokeCount > 0
                        recomputePreview()
                    } label: {
                        Label(String(localized: "撤销"), systemImage: "arrow.uturn.backward")
                            .font(.system(size: 13))
                    }
                    .disabled(!canUndo)
                    .foregroundColor(canUndo ? .holoToolText : .holoToolTextSecondary)
                    Button {
                        showResetConfirm = true
                    } label: {
                        Label(String(localized: "重置"), systemImage: "arrow.counterclockwise")
                            .font(.system(size: 13))
                    }
                    .foregroundColor(.holoToolTextSecondary)
                }

                Text(String(localized: "单指涂抹修边，双指可放大细节"))
                    .font(.system(size: 11))
                    .foregroundColor(.holoToolTextSecondary)
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .background(Color.holoToolBackground)
        .navigationTitle(String(localized: "修边"))
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "取消")) { onCancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "完成")) { onDone() }
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .alert(String(localized: "重置全部修边？"), isPresented: $showResetConfirm) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "重置"), role: .destructive) {
                onReset()
                strokeCount = 0
                canUndo = false
                recomputePreview()
            }
        } message: {
            Text(String(localized: "将清除本次全部涂抹记录，恢复到自动抠图结果。"))
        }
        .onAppear { recomputePreview() }
    }

    /// 后台异步重算预览（进入/松手/撤销/重置时各一次）
    private func recomputePreview() {
        Task {
            let image = await refreshPreview()
            if let image { cachedPreview = image }
        }
    }

    private func brushOption(label: String, value: CGFloat) -> some View {
        Button {
            brush = value
        } label: {
            Text(label)
                .font(.system(size: 12, weight: brush == value ? .bold : .regular))
                .foregroundColor(brush == value ? .holoToolAction : .holoToolTextSecondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(brush == value ? Color.holoToolInset : Color.clear)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 几何（imagePixelSize 真源，不查预览）

    /// 画布内边距 10pt 的等比 fit 显示矩形（与 Image 布局一致）
    private func fittedImageRect(canvasSize: CGSize) -> CGRect {
        let pad: CGFloat = 10
        let inner = CGSize(width: canvasSize.width - pad * 2, height: canvasSize.height - pad * 2)
        guard inner.width > 0, inner.height > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0 else { return .zero }
        let scale = min(inner.width / imagePixelSize.width, inner.height / imagePixelSize.height)
        let w = imagePixelSize.width * scale
        let h = imagePixelSize.height * scale
        return CGRect(x: pad + (inner.width - w) / 2, y: pad + (inner.height - h) / 2,
                      width: w, height: h)
    }

    /// 将以画布中心缩放后的触点逆变换回原始画布坐标
    private func unscalePoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard zoomScale > 1.001 else { return point }
        let cx = size.width / 2
        let cy = size.height / 2
        return CGPoint(x: cx + (point.x - cx) / zoomScale,
                       y: cy + (point.y - cy) / zoomScale)
    }

    private func normalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let fit = fittedImageRect(canvasSize: size)
        guard fit.width > 0, fit.height > 0 else { return .zero }
        return CGPoint(x: (point.x - fit.minX) / fit.width,
                       y: (point.y - fit.minY) / fit.height)
    }

    private func liveStrokeOverlay(canvasSize: CGSize) -> some View {
        let fit = fittedImageRect(canvasSize: canvasSize)
        let lineWidth = max(4, (brush / zoomScale) * fit.width)
        return Path { path in
            guard let first = activeStrokePoints.first else { return }
            path.move(to: CGPoint(x: fit.minX + first.x * fit.width,
                                  y: fit.minY + first.y * fit.height))
            for p in activeStrokePoints.dropFirst() {
                path.addLine(to: CGPoint(x: fit.minX + p.x * fit.width,
                                         y: fit.minY + p.y * fit.height))
            }
        }
        .stroke(eraseMode ? Color.holoToolError.opacity(0.45) : Color.holoToolSuccess.opacity(0.45),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}

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
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // 拖动中只更新轨迹，零合成
                            let p = normalize(value.location, in: geo.size)
                            activeStrokePoints.append(p)
                        }
                        .onEnded { _ in
                            guard !activeStrokePoints.isEmpty else { return }
                            onStroke(activeStrokePoints, eraseMode, brush)
                            activeStrokePoints.removeAll()
                            strokeCount += 1
                            canUndo = true
                            recomputePreview()
                        }
                )
            }
            .frame(height: 340)

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
                        onReset()
                        strokeCount = 0
                        canUndo = false
                        recomputePreview()
                    } label: {
                        Label(String(localized: "重置"), systemImage: "arrow.counterclockwise")
                            .font(.system(size: 13))
                    }
                    .foregroundColor(.holoToolTextSecondary)
                }
            }
            .padding(.horizontal, 20)
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

    private func normalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let fit = fittedImageRect(canvasSize: size)
        guard fit.width > 0, fit.height > 0 else { return .zero }
        return CGPoint(x: (point.x - fit.minX) / fit.width,
                       y: (point.y - fit.minY) / fit.height)
    }

    private func liveStrokeOverlay(canvasSize: CGSize) -> some View {
        let fit = fittedImageRect(canvasSize: canvasSize)
        let lineWidth = max(4, brush * fit.width)
        return Path { path in
            guard let first = activeStrokePoints.first else { return }
            path.move(to: CGPoint(x: fit.minX + first.x * fit.width,
                                  y: fit.minY + first.y * fit.height))
            for p in activeStrokePoints.dropFirst() {
                path.addLine(to: CGPoint(x: fit.minX + p.x * fit.width,
                                         y: fit.minY + p.y * fit.height))
            }
        }
        .stroke(eraseMode ? Color.red.opacity(0.45) : Color.green.opacity(0.45),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}

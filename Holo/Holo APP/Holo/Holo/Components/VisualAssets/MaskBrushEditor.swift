//
//  MaskBrushEditor.swift
//  Holo
//
//  「修边」（方案 01 §3.3 / 02 §3.3）：擦除多余区域、恢复被去掉区域、撤销、重置。
//  手指涂抹直接改工作遮罩（归一化坐标笔画）；预览=工作图×当前遮罩实时合成；
//  撤销=从基线遮罩重放剩余笔画。系统分不出手和杯子时，这里是唯一的精修手段。
//

import SwiftUI

struct MaskBrushEditor: View {
    /// 遮罩真源在制作页 Model；编辑器只发笔画与预览
    let previewProvider: () -> CGImage?
    let onStroke: (_ points: [CGPoint], _ erase: Bool, _ brush: CGFloat) -> Void
    let onUndo: () -> Void
    let onReset: () -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var eraseMode = true
    @State private var brush: CGFloat = 0.06      // 归一化直径（相对画布宽）
    @State private var canUndo = false
    @State private var previewRev = 0

    /// 本次会话的笔画计数（驱动 canUndo；真源 undo 在 Model）
    @State private var strokeCount = 0

    var body: some View {
        HoloSheetScaffold(title: String(localized: "修边"),
                          onClose: onCancel,
                          primaryTitle: String(localized: "完成"),
                          primaryHint: String(localized: "涂掉多余的，涂错点撤销")) {
            VStack(spacing: 12) {
                // 画布
                GeometryReader { geo in
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.holoToolInset)
                        if let image = previewProvider() {
                            Image(uiImage: UIImage(cgImage: image))
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .padding(10)
                                .id(previewRev)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let p = normalize(value.location, in: geo.size)
                                onStroke([p], eraseMode, brush)
                                strokeCount += 1
                                canUndo = true
                                previewRev += 1
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
                            previewRev += 1
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
                            previewRev += 1
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

    private func normalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        // 画布含 10pt 内边距的等比 fit——按同几何反算归一化（与预览 provider 的布局一致）
        let pad: CGFloat = 10
        let inner = CGSize(width: size.width - pad * 2, height: size.height - pad * 2)
        guard inner.width > 0, inner.height > 0,
              let image = previewProvider() else { return .zero }
        let scale = min(inner.width / CGFloat(image.width), inner.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale
        let h = CGFloat(image.height) * scale
        let ox = pad + (inner.width - w) / 2
        let oy = pad + (inner.height - h) / 2
        return CGPoint(x: (point.x - ox) / max(w, 1), y: (point.y - oy) / max(h, 1))
    }
}

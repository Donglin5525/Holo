//
//  HoloScrubGestureOverlay.swift
//  Holo
//
//  图表「点按 / 长按后拖动」选点覆盖层：回调触点坐标，由调用方换算成槽位。
//  原为 HoloHeatmap 私有实现，2026-11-21 年鉴卡复用时抽出（行为不变）。
//  长按 0.25s 才进入拖动，不抢外层 ScrollView 的纵向滚动。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
struct HoloScrubGestureOverlay: UIViewRepresentable {
    let onSelect: (CGPoint) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.25
        hold.allowableMovement = 10
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: hold)
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.onSelect = onSelect }
    final class Coordinator: NSObject {
        var onSelect: (CGPoint) -> Void
        init(onSelect: @escaping (CGPoint) -> Void) { self.onSelect = onSelect }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { onSelect(gesture.location(in: gesture.view)) }
        }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began || gesture.state == .changed { onSelect(gesture.location(in: gesture.view)) }
        }
    }
}

#else
/// macOS：无 UILongPress/UITap 体系，用带位置的点按 + 长按拖动等价实现
struct HoloScrubGestureOverlay: View {
    let onSelect: (CGPoint) -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { location in
                onSelect(location)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSelect(value.location)
                    }
            )
    }
}
#endif

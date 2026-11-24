//
//  HoloInkStrikeText.swift
//  Holo
//
//  任务完成「一笔划掉」（2026-11-23 审美七项 P2）：完成时一条墨线从左往右划过
//  标题，划完后文字淡为完成色；撤回时墨线淡出、文字色立即恢复。
//  首次出现的已完成行直接显示完成态，不重播。
//
//  动效开关：设置「任务纸面动效」（HoloTaskMotionRolloutPolicy.isEnabled）与
//  系统「减弱动态效果」任一关闭，即直接切换完成态、不扫线。
//

import SwiftUI

/// 划掉文本：底层正常排版承载文字与旁白，上层同排版透明文字只负责出墨线，
/// 前缘遮罩按进度从左往右露出（两行标题会被同时划过，像一支笔横扫过去）。
struct HoloInkStrikeText: View {
    let text: String
    /// 是否处于划掉态（调用方自行组合「完成中 / 已完成」）
    let isStruck: Bool
    let font: Font
    /// 未完成文字色
    let activeColor: Color
    /// 墨线划完后淡入的完成文字色
    let doneColor: Color
    /// 墨线颜色（项目口径：holoToolText.opacity(0.75)，不用橙色）
    let strikeColor: Color
    var lineLimit: Int = 2

    @State private var progress: CGFloat
    @State private var isSettled: Bool
    @State private var hasAppeared = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 是否允许播放扫线（任务纸面动效开关 + 减弱动态效果）
    private var allowsMotion: Bool {
        HoloTaskMotionRolloutPolicy.isEnabled && !reduceMotion
    }

    init(text: String, isStruck: Bool, font: Font, activeColor: Color,
         doneColor: Color, strikeColor: Color, lineLimit: Int = 2) {
        self.text = text
        self.isStruck = isStruck
        self.font = font
        self.activeColor = activeColor
        self.doneColor = doneColor
        self.strikeColor = strikeColor
        self.lineLimit = lineLimit
        // 首次出现即已完成：直接呈现完成态、不播放（State 初值只在首次插入层级时生效）
        _progress = State(initialValue: isStruck ? 1 : 0)
        _isSettled = State(initialValue: isStruck)
    }

    var body: some View {
        baseText
            .overlay(alignment: .leading) {
                strikeText
                    .mask(alignment: .leading) {
                        GeometryReader { proxy in
                            Rectangle()
                                .frame(width: proxy.size.width * progress)
                        }
                    }
            }
            .onChange(of: isStruck) { _, struck in
                guard hasAppeared else { return }
                strike(to: struck)
            }
            .onAppear { hasAppeared = true }
    }

    /// 底层：真实文字与颜色，旁白只读这一层
    private var baseText: some View {
        Text(text)
            .font(font)
            .foregroundColor(isSettled ? doneColor : activeColor)
            .lineLimit(lineLimit)
    }

    /// 上层：同排版透明文字，删除线颜色照常绘制，被前缘遮罩按进度露出。
    /// 备选（若模拟器实测 .clear 文字不绘制删除线）：把下面 foregroundStyle 一行换成
    /// .foregroundColor(isSettled ? doneColor : activeColor)——文字与底层同色完全重合，只多出墨线。
    private var strikeText: some View {
        Text(text)
            .font(font)
            .strikethrough(true, color: strikeColor)
            .foregroundStyle(.clear)
            .lineLimit(lineLimit)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// isStruck 变化：true = 扫线、划完文字变淡；false = 墨线淡出、文字色立即恢复
    private func strike(to struck: Bool) {
        guard allowsMotion else {
            progress = struck ? 1 : 0
            isSettled = struck
            return
        }
        if struck {
            // 时长取自 HoloAnimation.inkStrikeDuration（令牌只存了时长，曲线在此处定义）
            withAnimation(.easeOut(duration: HoloAnimation.inkStrikeDuration)) {
                progress = 1
            }
            // 文字变淡推迟到墨线划完再开始
            withAnimation(HoloAnimation.inkStrikeSettle.delay(HoloAnimation.inkStrikeDuration)) {
                isSettled = true
            }
        } else {
            withAnimation(HoloAnimation.reducedFade) { progress = 0 }
            isSettled = false
        }
    }
}

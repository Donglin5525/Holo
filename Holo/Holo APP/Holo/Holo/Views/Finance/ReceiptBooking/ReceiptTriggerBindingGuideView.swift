//
//  ReceiptTriggerBindingGuideView.swift
//  Holo
//
//  图片快捷记账 · 绑定一键触发指引（2026-10-24 用户反馈：建好快捷指令后
//  不知道怎么去系统设置里绑触发按钮）。按 HTML 原型 1:1 实装：
//  第一步建指令 → 第二步按机型绑定（操作按钮 / 轻点背面 / 悬浮球）→ 日常用法 + FAQ。
//

import SwiftUI

struct ReceiptTriggerBindingGuideView: View {

    @Environment(\.dismiss) private var dismiss

    enum DeviceTab { case actionButton, noButton }
    enum AssistTab { case backTap, assistiveTouch }

    @State private var deviceTab: DeviceTab = .actionButton
    @State private var assistTab: AssistTab = .backTap
    @State private var expandedFAQ: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                hero
                buildCard
                bindingSection
                switch deviceTab {
                case .actionButton: actionButtonPanel
                case .noButton: assistivePanel
                }
                usageCard
                faqCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 30)
        }
        .background(Color.holoBackground)
        .navigationTitle(Text("绑定一键触发"))
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: HoloToolbarPlacement.topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoToolTextSecondary)
                }
                .accessibilityLabel(Text("关闭"))
            }
        }
        .holoSheetShell()
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("绑定一键触发")
                .font(.system(size: 23, weight: .bold))
            Text("三步搞定：建指令 → 绑按钮 → 按一下记账。")
                .font(.system(size: 13))
                .foregroundStyle(Color.holoTextSecondary)
        }
        .padding(.top, 6)
    }

    // MARK: - 第一步 · 建指令

    private var buildCard: some View {
        guideCard {
            cardTitle(number: "1", title: "建好快捷指令", trailing: skipBadge)
            stepRow(1) {
                Text("打开「快捷指令」App，右上角 ")
                    + Text("＋").bold()
                    + Text(" 新建。")
            }
            stepRow(2) {
                Text("添加操作：搜「")
                    + Text("截屏").bold()
                    + Text("」加入（拍小票就搜「")
                    + Text("拍照").bold()
                    + Text("」）。")
            }
            stepRow(3) {
                Text("再搜「")
                    + Text("识别图片并记账").bold()
                    + Text("」加入，图片会自动接上。")
            }
            stepRow(4) {
                Text("改个好认的名字，如「")
                    + Text("记一笔").bold()
                    + Text("」→ 完成。")
            }
        }
    }

    private var skipBadge: some View {
        Text("已建好，跳过")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.holoSuccessText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.holoSuccess.opacity(0.14)))
    }

    // MARK: - 第二步 · 绑定触发位置

    private var bindingSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("2 · 绑定触发位置")
                .font(.system(size: 16.5, weight: .bold))
            HStack(spacing: 3) {
                deviceTabButton(.actionButton, icon: "iphone", title: "有操作按钮")
                deviceTabButton(.noButton, icon: nil, title: "没有操作按钮")
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 12).fill(Self.tabTrackColor))
        }
    }

    private func deviceTabButton(_ tab: DeviceTab, icon: String?, title: String) -> some View {
        let selected = deviceTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { deviceTab = tab }
        } label: {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Self.tabThumbColor : .clear))
            .foregroundStyle(selected ? Color.holoTextPrimary : Color.holoTextSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var actionButtonPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceNote {
                Text("iPhone 15 Pro 及之后全系").bold()
                    + Text("适用。按钮在手机")
                    + Text("左侧、音量键上方").bold()
                    + Text("。")
            }
            guideCard {
                sideButtonDiagram
                cardTitle(number: "A", title: "操作按钮")
                stepRow(1) {
                    Text("「设置」→「")
                        + Text("操作按钮").bold()
                        + Text("」。")
                }
                stepRow(2) {
                    Text("功能滑到「")
                        + Text("快捷指令").bold()
                        + Text("」，点「选择快捷指令…」勾选你那条。")
                }
                stepRow(3) {
                    Text("回桌面")
                        + Text("长按操作按钮").bold()
                        + Text("，跑起来即成功。")
                }
                hintRow {
                    Text("原功能（如手电筒）会被替换；iOS 26 可配多个功能：")
                        + Text("轻按").bold()
                        + Text("切换、")
                        + Text("长按").bold()
                        + Text("执行。")
                }
            }
        }
    }

    private var assistivePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceNote {
                Text("iPhone 15 及更早机型").bold()
                    + Text("适用。入口都在：设置 → 辅助功能 → 触控。")
            }
            HStack(spacing: 8) {
                assistTabButton(.backTap, icon: "hand.tap", title: "B1 · 轻点背面（推荐）")
                assistTabButton(.assistiveTouch, icon: "dot.circle", title: "B2 · 悬浮球")
            }
            switch assistTab {
            case .backTap: backTapCard
            case .assistiveTouch: assistiveTouchCard
            }
        }
    }

    private func assistTabButton(_ tab: AssistTab, icon: String, title: String) -> some View {
        let selected = assistTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { assistTab = tab }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.holoPrimary.opacity(0.10) : Color.holoCardBackground))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.holoPrimary : Self.guideBorder, lineWidth: selected ? 1.5 : 1))
            .foregroundStyle(selected ? Color.holoPrimaryDark : Color.holoTextSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var backTapCard: some View {
        guideCard {
            backTapDiagram
            cardTitle(number: "B1", title: "轻点背面")
            stepRow(1) {
                Text("「设置」→「辅助功能」→「触控」→ 最底「")
                    + Text("轻点背面").bold()
                    + Text("」。")
            }
            stepRow(2) {
                Text("选「")
                    + Text("轻点两下").bold()
                    + Text("」→ 拉到「快捷指令」分组勾选你那条。")
            }
            stepRow(3) {
                Text("食指在背面上半部")
                    + Text("敲两下").bold()
                    + Text("测试。")
            }
            hintRow {
                Text("要「敲」不要摸；厚壳会减弱感应；平放桌面不触发。")
            }
        }
    }

    private var assistiveTouchCard: some View {
        guideCard {
            assistiveTouchDiagram
            cardTitle(number: "B2", title: "悬浮球（辅助触控）")
            stepRow(1) {
                Text("「设置」→「辅助功能」→「触控」→ 打开「")
                    + Text("辅助触控").bold()
                    + Text("」。")
            }
            stepRow(2) {
                Text("「自定操作」点「")
                    + Text("单点").bold()
                    + Text("」→ 拉到「快捷指令」分组勾选你那条。")
            }
            stepRow(3) {
                Text("单点悬浮球").bold()
                    + Text("测试。")
            }
            hintRow {
                Text("悬浮球常驻屏幕；把「闲置时不透明度」调低可变淡，不碍眼。")
            }
        }
    }

    // MARK: - 第三步 · 日常这样用

    private var usageCard: some View {
        guideCard {
            cardTitle(number: "3", title: "日常这样用")
            usageRow(icon: "barcode.viewfinder") {
                Text("网购 / 扫码支付：").bold()
                    + Text("停在成功页按一下，自动截屏入账。")
            }
            usageDivider
            usageRow(icon: "camera") {
                Text("纸质小票：").bold()
                    + Text("触发后拍一张就行。")
            }
            usageDivider
            usageRow(icon: "checkmark.circle.fill") {
                Text("拿不准的进「待复核」").bold()
                    + Text("；记错 10 分钟内可撤销。")
            }
        }
    }

    private var usageDivider: some View {
        Divider()
    }

    private func usageRow(icon: String, @ViewBuilder text: () -> Text) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.holoPrimary)
                .frame(width: 20)
                .padding(.top, 2)
            text()
                .font(.system(size: 13))
                .lineSpacing(3)
        }
        .padding(.vertical, 7)
    }

    // MARK: - FAQ

    private var faqCard: some View {
        guideCard {
            cardTitle(number: "?", title: "常见问题")
            VStack(spacing: 0) {
                ForEach(Self.faqItems.indices, id: \.self) { index in
                    faqRow(index)
                    if index < Self.faqItems.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func faqRow(_ index: Int) -> some View {
        let expanded = expandedFAQ == index
        let item = Self.faqItems[index]
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedFAQ = expanded ? nil : index
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.holoTextSecondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .padding(.top, 3)
                    Text(item.question)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.holoTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(item.answer)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.holoTextSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 23)
                    .padding(.bottom, 10)
            }
        }
    }

    private static let faqItems: [(question: String, answer: String)] = [
        ("按了没反应？", "确认勾选的是这条指令；背面要「敲」不是摸；快捷指令 App 底部可看运行记录。"),
        ("提示「请先打开 Holo 完成设置」？", "Holo → 财务 → 设置 → 图片自动记账，开启「AI 图片识别」。"),
        ("提示「今天的识别次数用完了」？", "次日自动恢复；图还在相册里，明天再触发一次。"),
        ("运行了但没入账？", "去「图片自动记账」页看「最近结果」和「待复核」。"),
        ("结果通知收不到？", "设置页打开「完成后通知我」，再到系统设置允许 Holo 通知。"),
        ("不想绑按钮？", "对 Siri 说「用 Holo 记账」选图识别；或把指令「添加到主屏幕」。"),
    ]

    // MARK: - 示意图（CSS 原型 1:1）

    /// 方案 A：iPhone 侧边示意 —— 左侧 1 颗橙色操作按钮 + 2 颗灰色音量键
    private var sideButtonDiagram: some View {
        diagramShell {
            ZStack(alignment: .topLeading) {
                phoneBody
                Capsule()
                    .fill(Color.holoPrimary)
                    .frame(width: 4, height: 20)
                    .shadow(color: Color.holoPrimary.opacity(0.45), radius: 2.5)
                    .offset(x: -6.5, y: 14)
                    .accessibilityHidden(true)
                Capsule()
                    .fill(Self.diagramGray)
                    .frame(width: 4, height: 16)
                    .offset(x: -6.5, y: 52)
                Capsule()
                    .fill(Self.diagramGray)
                    .frame(width: 4, height: 16)
                    .offset(x: -6.5, y: 72)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                (Text("橙色这颗就是操作按钮").bold().foregroundStyle(Color.holoPrimaryDark)
                    + Text("。").foregroundStyle(Color.holoTextSecondary))
                    .font(.system(size: 12))
                    .lineSpacing(3)
                pressPill(icon: "hand.tap", text: "长按 ≈1 秒触发")
            }
        } accessibility: {
            "示意图：手机左侧上方是橙色的操作按钮，下方是两个音量键"
        }
    }

    /// 方案 B1：手机背面示意 —— 上半部虚线高亮区 = 轻敲位置
    private var backTapDiagram: some View {
        diagramShell {
            ZStack(alignment: .topLeading) {
                phoneBody(fill: Color.holoDynamic(light: UIColor(red: 0.937, green: 0.918, blue: 0.886, alpha: 1),
                                                  dark: UIColor(red: 0.24, green: 0.22, blue: 0.19, alpha: 1)))
                RoundedRectangle(cornerRadius: 6)
                    .fill(Self.diagramGray)
                    .frame(width: 18, height: 18)
                    .offset(x: 8, y: 8)
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.holoPrimary, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.holoPrimary.opacity(0.10)))
                    .frame(width: 52, height: 44)
                    .offset(x: 6, y: 6)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                (Text("虚线区 = 轻敲位置").bold().foregroundStyle(Color.holoPrimaryDark)
                    + Text("：背面上半部、摄像头下方。").foregroundStyle(Color.holoTextSecondary))
                    .font(.system(size: 12))
                    .lineSpacing(3)
                pressPill(icon: "hand.tap", text: "敲两下触发")
            }
        } accessibility: {
            "示意图：手机背面上半部的虚线区域就是轻敲位置"
        }
    }

    /// 方案 B2：屏幕示意 —— 右侧半透明悬浮球
    private var assistiveTouchDiagram: some View {
        diagramShell {
            ZStack(alignment: .topLeading) {
                phoneBody
                Circle()
                    .fill(Color.holoDynamic(light: UIColor(white: 0.16, alpha: 0.72),
                                            dark: UIColor(white: 0.9, alpha: 0.65)))
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.18), radius: 3)
                    .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 4))
                    .offset(x: 36, y: 42)
                Text("记一笔")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.holoPrimary))
                    .offset(x: 12, y: 70)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                (Text("屏幕边缘出现").foregroundStyle(Color.holoTextSecondary)
                    + Text("半透明悬浮球").bold().foregroundStyle(Color.holoPrimaryDark)
                    + Text("，一点就记账。").foregroundStyle(Color.holoTextSecondary))
                    .font(.system(size: 12))
                    .lineSpacing(3)
                pressPill(icon: "dot.circle", text: "单点触发")
            }
        } accessibility: {
            "示意图：屏幕右缘有一个半透明圆形悬浮球"
        }
    }

    private var phoneBody: some View {
        phoneBody(fill: Self.phoneFillColor)
    }

    private func phoneBody(fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(fill)
            .frame(width: 64, height: 118)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Self.phoneBorderColor, lineWidth: 3))
    }

    private func diagramShell(
        @ViewBuilder device: () -> some View,
        @ViewBuilder label: () -> some View,
        accessibility: @escaping () -> String
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            device()
                .accessibilityLabel(Text(accessibility()))
            label()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.holoNestedCardBackground))
        .padding(.bottom, 8)
    }

    private func pressPill(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.holoPrimary)
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.holoTextPrimary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.holoCardBackground))
        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        .padding(.top, 5)
    }

    // MARK: - 通用小件

    private func guideCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.holoCardBackground))
        .shadow(color: Color.black.opacity(0.05), radius: 1, y: 1)
    }

    private func cardTitle(number: String, title: String, trailing: some View = EmptyView()) -> some View {
        HStack(alignment: .center, spacing: 8) {
            sectionNum(number)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.holoTextPrimary)
            Spacer(minLength: 6)
            trailing
        }
        .padding(.bottom, 8)
    }

    private func sectionNum(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.holoPrimary))
            .accessibilityHidden(true)
    }

    private func stepRow(_ n: Int, @ViewBuilder text: () -> Text) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.holoPrimaryDark)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.holoPrimary.opacity(0.14)))
                .accessibilityHidden(true)
            text()
                .font(.system(size: 13))
                .foregroundStyle(Color.holoTextPrimary)
                .lineSpacing(3)
                .padding(.top, 0.5)
        }
        .padding(.vertical, 5)
    }

    private func deviceNote(@ViewBuilder text: () -> Text) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.holoPrimaryDark)
                .padding(.top, 1)
            text()
                .font(.system(size: 12.5))
                .foregroundStyle(Color.holoDynamic(light: UIColor(red: 0.54, green: 0.27, blue: 0.07, alpha: 1),
                                                   dark: UIColor(red: 0.996, green: 0.843, blue: 0.667, alpha: 1)))
                .lineSpacing(3)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.holoPrimary.opacity(0.12)))
    }

    private func hintRow(@ViewBuilder text: () -> Text) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .padding(.top, 2)
            text()
                .font(.system(size: 12))
                .lineSpacing(3)
        }
        .foregroundStyle(Color.holoDynamic(light: UIColor(red: 0.573, green: 0.38, blue: 0.055, alpha: 1),
                                           dark: UIColor(red: 0.91, green: 0.784, blue: 0.514, alpha: 1)))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.holoDynamic(light: UIColor(red: 1, green: 0.965, blue: 0.914, alpha: 1),
                                                                              dark: UIColor(red: 0.20, green: 0.17, blue: 0.11, alpha: 1))))
        .padding(.top, 9)
    }

    // MARK: - 原型色板（亮暗双版）

    private static let tabTrackColor = Color.holoDynamic(light: UIColor(red: 0.937, green: 0.914, blue: 0.875, alpha: 1),
                                                         dark: UIColor(red: 0.20, green: 0.18, blue: 0.16, alpha: 1))
    private static let tabThumbColor = Color.holoDynamic(light: .white, dark: UIColor(red: 0.25, green: 0.23, blue: 0.20, alpha: 1))
    private static let guideBorder = Color.holoDynamic(light: UIColor(red: 0.929, green: 0.906, blue: 0.867, alpha: 1),
                                                       dark: UIColor(red: 0.28, green: 0.26, blue: 0.23, alpha: 1))
    private static let diagramGray = Color.holoDynamic(light: UIColor(red: 0.608, green: 0.58, blue: 0.541, alpha: 1),
                                                       dark: UIColor(red: 0.55, green: 0.53, blue: 0.49, alpha: 1))
    private static let phoneFillColor = Color.holoDynamic(light: .white, dark: UIColor(red: 0.24, green: 0.23, blue: 0.20, alpha: 1))
    private static let phoneBorderColor = Color.holoDynamic(light: UIColor(red: 0.165, green: 0.153, blue: 0.141, alpha: 1),
                                                            dark: UIColor(red: 0.79, green: 0.765, blue: 0.72, alpha: 1))
}

#Preview("绑定指引") {
    NavigationStack {
        ReceiptTriggerBindingGuideView()
    }
}

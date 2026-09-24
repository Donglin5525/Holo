//
//  HoloSidebarView.swift
//  Holo
//
//  iPad v2 骨架：左侧边栏导航（docs/ipad-adaptation/v2-plan.md 阶段 2）。
//  仅在 expanded 宽度（≥1024pt）由 ContentView 挂载，iPhone 路径不经过此视图。
//

import SwiftUI

// MARK: - 侧边栏目的地

/// 侧边栏条目。模块类条目直接映射常驻栈 ActiveScreen；
/// 个人 / 设置在 HomeView 侧以页面层（非弹窗）呈现。
enum HoloSidebarDestination: String, CaseIterable, Identifiable, Equatable {
    case today
    case thoughts
    case finance
    case tasks
    case habits
    case memoryGallery
    case health
    case ai
    case profile
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return String(localized: "今天")
        case .thoughts: return String(localized: "想法")
        case .finance: return String(localized: "财务")
        case .tasks: return String(localized: "任务")
        case .habits: return String(localized: "习惯")
        case .memoryGallery: return String(localized: "记忆长廊")
        case .health: return String(localized: "健康")
        case .ai: return String(localized: "AI 对话")
        case .profile: return String(localized: "个人")
        case .settings: return String(localized: "设置")
        }
    }

    var icon: String {
        switch self {
        case .today: return "sun.max.fill"
        case .thoughts: return "lightbulb.fill"
        case .finance: return "yensign.circle.fill"
        case .tasks: return "checkmark.circle.fill"
        case .habits: return "arrow.2.squarepath"
        case .memoryGallery: return "book.fill"
        case .health: return "heart.fill"
        case .ai: return "sparkles"
        case .profile: return "person.fill"
        case .settings: return "gearshape.fill"
        }
    }

    /// 主导航区条目（分隔线之上）
    static let mainItems: [HoloSidebarDestination] = [
        .today, .thoughts, .finance, .tasks, .habits, .memoryGallery, .health, .ai
    ]

    /// 次级区条目（分隔线之下）
    static let secondaryItems: [HoloSidebarDestination] = [.profile, .settings]

    /// 是否映射到常驻模块栈
    var activeScreen: ActiveScreen? {
        switch self {
        case .thoughts: return .thoughts
        case .finance: return .finance
        case .tasks: return .tasks
        case .habits: return .habits
        case .memoryGallery: return .memoryGallery
        case .health: return .health
        case .ai: return .ai
        case .today, .profile, .settings: return nil
        }
    }

    /// 由常驻模块反查侧边栏条目
    static func destination(for screen: ActiveScreen) -> HoloSidebarDestination {
        HoloSidebarDestination(rawValue: screen.rawValue) ?? .today
    }
}

// MARK: - 侧边栏视图

struct HoloSidebarView: View {

    /// 当前选中的目的地（由 ContentView 持有）
    @Binding var selection: HoloSidebarDestination

    /// 侧边栏形态：常驻全宽（图标+文字）或窄条（仅图标，目的地始终可见可点）
    var visibility: HoloLayoutPolicy.SidebarVisibility = .persistent

    /// 形态切换（收起/展开；nil 形态下不显示切换按钮）
    var onToggleVisibility: ((HoloLayoutPolicy.SidebarVisibility?) -> Void)? = nil

    /// 底部「快速记录」动作（⌘N 同款语义）
    let onQuickCapture: () -> Void

    private var isRail: Bool { visibility == .rail }

    var body: some View {
        VStack(spacing: 0) {
            if isRail {
                railHeader
            } else {
                brandHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 6)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(HoloSidebarDestination.mainItems) { item in
                        sidebarRow(item)
                    }

                    Divider()
                        .background(Color.holoBorder)
                        .padding(.vertical, 10)
                        .padding(.horizontal, isRail ? 10 : 12)

                    ForEach(HoloSidebarDestination.secondaryItems) { item in
                        sidebarRow(item)
                    }
                }
                .padding(.horizontal, isRail ? 8 : 12)
            }

            quickCaptureButton
                .padding(.horizontal, isRail ? 10 : 14)
                .padding(.top, 8)
                .padding(.bottom, 14)

            if let onToggleVisibility, !isRail {
                collapseButton
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else if let onToggleVisibility, isRail {
                expandButton
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
            }
        }
        .frame(width: isRail ? HoloLayoutPolicy.sidebarRailWidth : HoloAdaptiveLayout.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Self.sidebarBackground.ignoresSafeArea())
        .animation(HoloAnimation.standard, value: visibility)
    }

    // MARK: - 子视图

    /// 窄条品牌区：Holo 圆点
    private var railHeader: some View {
        Circle()
            .fill(Color.holoPrimary)
            .frame(width: 9, height: 9)
            .padding(.top, 24)
            .padding(.bottom, 10)
            .accessibilityHidden(true)
    }

    /// 品牌区：Holo + 日期问候
    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Holo")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                    .kerning(0.5)

                Circle()
                    .fill(Color.holoPrimary)
                    .frame(width: 7, height: 7)
            }

            Text(Self.dateLine)
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单行导航条目（窄条形态只渲染图标）
    private func sidebarRow(_ item: HoloSidebarDestination) -> some View {
        let isSelected = selection == item
        return Button {
            guard selection != item else { return }
            selection = item
        } label: {
            Group {
                if isRail {
                    Image(systemName: item.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
                        .frame(width: 40, height: 40)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
                            .frame(width: 20)

                        Text(item.title)
                            .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? .holoTextPrimary : .holoTextSecondary)

                        Spacer(minLength: 0)

                        if let number = item.shortcutNumber {
                            Text("⌘\(number)")
                                .font(.system(size: 10))
                                .foregroundColor(.holoTextPlaceholder)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(isSelected ? Color.holoPrimary.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .holoHover()
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 底部快速记录（窄条形态只渲染 + 号）
    private var quickCaptureButton: some View {
        Button(action: onQuickCapture) {
            Group {
                if isRail {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: HoloRadius.md)
                                .fill(Color.holoPrimary)
                        )
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text(String(localized: "快速记录"))
                            .font(.system(size: 14, weight: .semibold))
                        Text("⌘N")
                            .font(.system(size: 10, weight: .regular))
                            .opacity(0.7)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.lg)
                            .fill(LinearGradient(
                                colors: [Color.holoPrimary, Color.holoPrimaryDark],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                    )
                    .shadow(color: Color.holoPrimary.opacity(0.3), radius: 12, x: 0, y: 5)
                }
            }
        }
        .buttonStyle(.plain)
        .holoHover()
        .accessibilityLabel(String(localized: "快速记录"))
    }

    /// 常驻形态底部的收起按钮（«）
    private var collapseButton: some View {
        Button {
            onToggleVisibility?(.rail)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                Text(String(localized: "收起边栏"))
                    .font(.system(size: 12))
            }
            .foregroundColor(.holoTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.holoPrimary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .holoHover()
        .accessibilityLabel(String(localized: "收起边栏"))
    }

    /// 窄条形态底部的展开按钮（»）
    private var expandButton: some View {
        Button {
            onToggleVisibility?(.persistent)
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .fill(Color.holoPrimary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .holoHover()
        .accessibilityLabel(String(localized: "展开边栏"))
    }

    // MARK: - 辅助

    /// 侧边栏底色：比内容区深一档（深色）/ 浅一档（浅色），让两区有层次
    static let sidebarBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.075, blue: 0.082, alpha: 1)
            : UIColor(red: 0.945, green: 0.941, blue: 0.925, alpha: 1)
    })

    /// 「9月5日 周五」
    private static var dateLine: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEE"
        return formatter.string(from: Date())
    }
}

// MARK: - 快捷键序号

extension HoloSidebarDestination {

    /// 侧边栏 Cmd 直跳序号（⌘1…⌘9，与设计稿一致；设置无序号走 ⌘,）
    var shortcutNumber: Int? {
        switch self {
        case .today: return 1
        case .thoughts: return 2
        case .finance: return 3
        case .tasks: return 4
        case .habits: return 5
        case .memoryGallery: return 6
        case .health: return 7
        case .ai: return 8
        case .profile: return 9
        case .settings: return nil
        }
    }

    /// 由序号反查（⌘N 用）
    static func destination(shortcutNumber number: Int) -> HoloSidebarDestination? {
        allCases.first { $0.shortcutNumber == number }
    }
}

//
//  MemoryTimeChapterHeader.swift
//  Holo
//
//  日 / 周 / 月共用的时间章节视觉：大时间、范围标题、可验证证据与低噪音筛选。
//

import SwiftUI

struct MemoryTimeChapterHeader<DateControl: View>: View {
    let presentation: MemoryTimeChapterPresentation
    @Binding var moduleFilter: CalendarModule?
    /// 底色随所处容器：周/月用全局背景，日回放册页用纸色（pinned 头必须不透明，避免滚动内容透出）
    private let backgroundColor: Color
    private let dateControl: DateControl

    init(
        presentation: MemoryTimeChapterPresentation,
        moduleFilter: Binding<CalendarModule?>,
        backgroundColor: Color = .holoBackground,
        @ViewBuilder dateControl: () -> DateControl
    ) {
        self.presentation = presentation
        self._moduleFilter = moduleFilter
        self.backgroundColor = backgroundColor
        self.dateControl = dateControl()
    }

    var body: some View {
        HStack(spacing: 12) {
            dateControl
                .layoutPriority(2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(presentation.title)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if let badge = presentation.currentBadge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.holoPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.holoPrimary.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }

                Text(presentation.evidence)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 2)
            filterMenu
        }
        .padding(.horizontal, HoloSpacing.md)
        .frame(minHeight: 92)
        .background(
            LinearGradient(
                colors: [backgroundColor.opacity(0.99), backgroundColor.opacity(0.94)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color.holoPrimary.opacity(0.68), Color.holoPrimary.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 104, height: 1)
            .padding(.leading, HoloSpacing.md)
        }
        .zIndex(10)
    }

    private var filterMenu: some View {
        Menu {
            filterButton(title: "全部记录", module: nil)
            ForEach(CalendarModule.allCases) { module in
                filterButton(title: module.displayName, module: module)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10, weight: .semibold))
                Text(moduleFilter?.displayName ?? "全部")
                    .lineLimit(1)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.holoTextSecondary)
            .padding(.horizontal, 10)
            .frame(minWidth: 66, minHeight: 34)
            .background(Color.holoCardBackground.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .stroke(Color.holoBorder.opacity(0.55), lineWidth: 1)
            )
        }
        .accessibilityLabel("筛选，当前为\(moduleFilter?.displayName ?? "全部记录")")
    }

    private func filterButton(title: String, module: CalendarModule?) -> some View {
        Button {
            withAnimation(HoloAnimation.quick) { moduleFilter = module }
        } label: {
            Label(title, systemImage: moduleFilter == module ? "checkmark" : "circle")
        }
    }
}

struct MemoryNarrativeStrip: View {
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.holoPrimary)

            Text(text)
                .font(.system(size: 12, weight: .medium, design: .serif))
                .foregroundColor(.holoTextSecondary)
                .lineLimit(2)
                .lineSpacing(3)

            Spacer(minLength: 4)

            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [Color.holoPrimary.opacity(0.075), Color.holoCardBackground.opacity(0.38)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.holoPrimary.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

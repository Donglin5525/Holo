//
//  PersonalMembershipCard.swift
//  Holo
//
//  个人页会员入口：用紧凑横条保留徽章与会员状态，大字体时允许自然增高。
//

import SwiftUI

struct PersonalMembershipCard: View {
    let isPlusActive: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: HoloSpacing.md) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        emblem
                        membershipCopy
                    }
                } else {
                    HStack(spacing: HoloSpacing.md) {
                        emblem
                        membershipCopy
                    }
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HoloPlusTheme.accentText)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm + HoloSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HoloPlusTheme.darkGradient)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .stroke(HoloPlusTheme.strokeColor, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var emblem: some View {
        HoloPlusEmblem(size: 56, tier: isPlusActive ? .plus : .free)
    }

    private var membershipCopy: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Text("Holo Plus")
                .holoText(.sectionTitle)
                .foregroundStyle(HoloPlusTheme.accentText)

            Text(isPlusActive ? String(localized: "会员权益已生效") : String(localized: "免费版 · 了解 Plus"))
                .holoText(.metadata)
                .foregroundStyle(HoloPlusTheme.subtleText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

//
//  HoloPlusBenefitComparisonTable.swift
//  Holo
//
//  Holo Plus 权益对比表。
//  全 App 免费 vs Plus 档位差异的唯一展示来源：
//  会员中心内嵌本表，付费墙通过「查看完整权益对比」打开 HoloPlusComparisonView。
//  数字与后端 quotaPolicy.js 对齐，改额度只动这里的 all 列表。
//
//  设计原则：克制。让"灰色 vs 橙色"的数字对比自己说话，不加多余装饰。
//

import SwiftUI

// MARK: - 权益数据模型

/// 一项权益在免费版 / Plus 版两侧的取值。
struct HoloPlusBenefit: Identifiable {
    /// 单元格取值：具体文字，或功能开关（✓ / ✗）。
    enum Value: Equatable {
        case text(String)
        case feature(Bool)
    }

    let id = UUID()
    let icon: String
    let name: String
    let freeValue: Value
    let plusValue: Value
}

enum HoloPlusBenefits {
    /// 免费版与 Plus 版的全部档位差异。
    /// 数值口径与后端 `HoloBackend/src/usage/quotaPolicy.js` 保持一致。
    static let all: [HoloPlusBenefit] = [
        .init(
            icon: "message.badge.waveform",
            name: "HoloAI 对话",
            freeValue: .text("15 次/天"),
            plusValue: .text("30 次/天")
        ),
        .init(
            icon: "brain.head.profile",
            name: "深度洞察",
            freeValue: .text("2 次/天"),
            plusValue: .text("10 次/天")
        ),
        .init(
            icon: "waveform",
            name: "语音识别",
            freeValue: .text("20 次/天"),
            plusValue: .text("50 次/天")
        ),
        .init(
            icon: "timer",
            name: "单条语音时长",
            freeValue: .text("60 秒"),
            plusValue: .text("5 分钟")
        ),
        .init(
            icon: "sparkles.rectangle.stack",
            name: "智能记账",
            freeValue: .text("20 次/天"),
            plusValue: .text("50 次/天")
        ),
        .init(
            icon: "checklist",
            name: "智能任务",
            freeValue: .text("20 次/天"),
            plusValue: .text("50 次/天")
        ),
        .init(
            icon: "calendar.badge.clock",
            name: "每周生活计划",
            freeValue: .text("1 次/周"),
            plusValue: .text("2 次/周")
        ),
        .init(
            icon: "memories",
            name: "记忆洞察刷新",
            freeValue: .text("1 次/周"),
            plusValue: .text("1 次/天")
        ),
        .init(
            icon: "waveform.circle",
            name: "语音启动小组件",
            freeValue: .feature(false),
            plusValue: .feature(true)
        ),
        .init(
            icon: "square.grid.2x2",
            name: "快捷控制台小组件",
            freeValue: .feature(false),
            plusValue: .feature(true)
        ),
        .init(
            icon: "chart.bar.xaxis",
            name: "财务小组件",
            freeValue: .feature(false),
            plusValue: .feature(true)
        ),
        .init(
            icon: "wand.and.stars",
            name: "随机漫步小组件",
            freeValue: .feature(false),
            plusValue: .feature(true)
        ),
    ]
}

// MARK: - 对比表视图

/// 免费 vs Plus 三列对比表。只读展示，不含购买逻辑。
struct HoloPlusBenefitComparisonTable: View {
    /// 高亮「当前方案」所在列，nil 表示不标记。
    var currentTierHighlight: Tier? = nil

    enum Tier {
        case free
        case plus
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow

            ForEach(HoloPlusBenefits.all) { benefit in
                CardDivider()
                benefitRow(benefit)
            }

        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.holoBorder.opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: 表头

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("功能")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            tierHeader(title: "免费版", tier: .free)
                .frame(width: 82)

            tierHeader(title: "Plus", tier: .plus)
                .frame(width: 82)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func tierHeader(title: String, tier: Tier) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                if tier == .plus {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(tier == .plus ? .system(size: 15, weight: .bold) : .holoLabel)
            }
            .foregroundColor(tier == .plus ? .holoPrimary : .holoTextSecondary)

            if currentTierHighlight == tier {
                Text("当前")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        tier == .plus ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.6)
                    )
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: 数据行

    @ViewBuilder
    private func benefitRow(_ benefit: HoloPlusBenefit) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // 功能名列：裸线条图标（无圆形底）+ 名称
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: benefit.icon)
                        .font(.system(size: 16))
                        .foregroundColor(.holoPrimary.opacity(0.8))
                        .frame(width: 20)

                    Text(benefit.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.holoTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 免费版列
                valueCell(benefit.freeValue, isPlus: false)
                    .frame(width: 82)

                // Plus 列
                valueCell(benefit.plusValue, isPlus: true)
                    .frame(width: 82)
            }
            .frame(minHeight: 52)
            .padding(.horizontal, HoloSpacing.md)
        }
    }

    @ViewBuilder
    private func valueCell(_ value: HoloPlusBenefit.Value, isPlus: Bool) -> some View {
        switch value {
        case .text(let text):
            Text(text)
                .font(.system(size: 15, weight: isPlus ? .bold : .medium))
                .foregroundColor(isPlus ? .holoPrimary : .holoTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        case .feature(let enabled):
            if enabled {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoPrimary)
            } else {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.holoTextSecondary.opacity(0.35))
            }
        }
    }
}

// MARK: - 完整对比页（付费墙入口用）

/// 纯展示的完整权益对比页，由付费墙「查看完整权益对比」以 sheet 形式打开。
struct HoloPlusComparisonView: View {
    @ObservedObject private var entitlementState = HoloEntitlementState.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    Text("免费版与 Holo Plus 对比")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    HoloPlusBenefitComparisonTable(
                        currentTierHighlight: entitlementState.isPlusActive ? .plus : .free
                    )

                    Text("所有记账、待办、想法等本地功能，免费版与 Plus 版完全一致，不受会员限制。")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("权益对比")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

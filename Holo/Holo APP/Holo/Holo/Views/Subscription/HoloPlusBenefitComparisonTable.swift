//
//  HoloPlusBenefitComparisonTable.swift
//  Holo
//
//  Holo Plus 权益对比表。
//  全 App 免费 vs Plus 档位差异的唯一展示来源：
//  会员中心内嵌本表，付费墙通过「查看全部权益对比」打开 HoloPlusComparisonView。
//  数字与后端 quotaPolicy.js 及客户端实际门禁 1:1 对齐，改额度只动这里。
//
//  设计原则（2026-11-24 反 AI 味编辑感）：纸底无卡、0.5pt 细线分层、无装饰图标堆砌、一页一橙。
//

import SwiftUI

// MARK: - 权益数据模型

/// 一项权益在免费版 / Plus 版两侧的取值。
struct HoloPlusBenefit: Identifiable {
    /// 单元格取值：具体文字，或功能开关（✓ / —）。
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

/// 权益分组（完整对比页按用户可理解的三大块分组呈现）。
struct HoloPlusBenefitGroup: Identifiable {
    let id: String
    let title: String
    let items: [HoloPlusBenefit]
}

enum HoloPlusBenefits {
    /// 按业务领域分组的全部免费 vs Plus 差异（与实际门禁 100% 对齐）。
    /// 数值口径与后端 `HoloBackend/src/usage/quotaPolicy.js` 保持一致。
    static let groups: [HoloPlusBenefitGroup] = [
        HoloPlusBenefitGroup(
            id: "ai",
            title: String(localized: "AI 主动理解与效率"),
            items: [
                .init(
                    icon: "sparkle.magnifyingglass",
                    name: String(localized: "一个发现"),
                    freeValue: .text(String(localized: "1 件/周")),
                    plusValue: .text(String(localized: "最多 5 件/周"))
                ),
                .init(
                    icon: "brain.head.profile",
                    name: String(localized: "深度洞察"),
                    freeValue: .text(String(localized: "1 次/天")),
                    plusValue: .text(String(localized: "10 次/天"))
                ),
                .init(
                    icon: "message.badge.waveform",
                    name: String(localized: "HoloAI 对话"),
                    freeValue: .text(String(localized: "15 次/天")),
                    plusValue: .text(String(localized: "30 次/天"))
                ),
                .init(
                    icon: "timer",
                    name: String(localized: "单条语音时长"),
                    freeValue: .text(String(localized: "60 秒")),
                    plusValue: .text(String(localized: "5 分钟"))
                ),
                .init(
                    icon: "waveform",
                    name: String(localized: "语音识别"),
                    freeValue: .text(String(localized: "20 次/天")),
                    plusValue: .text(String(localized: "50 次/天"))
                ),
                .init(
                    icon: "doc.text.magnifyingglass",
                    name: String(localized: "账单智能导入"),
                    freeValue: .feature(false),
                    plusValue: .feature(true)
                ),
                .init(
                    icon: "wand.and.stars",
                    name: String(localized: "AI 任务拆解"),
                    freeValue: .text(String(localized: "5 次/月")),
                    plusValue: .text(String(localized: "100 次/月"))
                ),
                .init(
                    icon: "memories",
                    name: String(localized: "记忆洞察刷新"),
                    freeValue: .text(String(localized: "1 次/周")),
                    plusValue: .text(String(localized: "1 次/天"))
                ),
                .init(
                    icon: "calendar.badge.clock",
                    name: String(localized: "每周生活计划"),
                    freeValue: .text(String(localized: "1 次/周")),
                    plusValue: .text(String(localized: "2 次/周"))
                ),
                .init(
                    icon: "text.badge.checkmark",
                    name: String(localized: "智能记账"),
                    freeValue: .text(String(localized: "20 次/天")),
                    plusValue: .text(String(localized: "50 次/天"))
                ),
                .init(
                    icon: "checklist",
                    name: String(localized: "智能任务"),
                    freeValue: .text(String(localized: "20 次/天")),
                    plusValue: .text(String(localized: "50 次/天"))
                ),
            ]
        ),
        HoloPlusBenefitGroup(
            id: "finance",
            title: String(localized: "财务进阶管理"),
            items: [
                .init(
                    icon: "chart.pie",
                    name: String(localized: "预算管理"),
                    freeValue: .feature(false),
                    plusValue: .feature(true)
                ),
                .init(
                    icon: "calendar.badge.plus",
                    name: String(localized: "财务分期"),
                    freeValue: .feature(false),
                    plusValue: .feature(true)
                ),
                .init(
                    icon: "arrow.triangle.2.circlepath",
                    name: String(localized: "自定义账单周期"),
                    freeValue: .feature(false),
                    plusValue: .feature(true)
                ),
                .init(
                    icon: "creditcard",
                    name: String(localized: "信用卡还款提醒"),
                    freeValue: .text(String(localized: "最多 3 张")),
                    plusValue: .text(String(localized: "不限张数"))
                ),
            ]
        ),
        HoloPlusBenefitGroup(
            id: "widgets_habits",
            title: String(localized: "桌面小组件与习惯保护"),
            items: [
                .init(
                    icon: "waveform.circle",
                    name: String(localized: "语音启动小组件"),
                    freeValue: .feature(false),
                    plusValue: .feature(true)
                ),
                .init(
                    icon: "square.grid.2x2",
                    name: String(localized: "快捷控制台小组件"),
                    freeValue: .feature(false),
                    plusValue: .feature(true)
                ),
                .init(
                    icon: "chart.bar.xaxis",
                    name: String(localized: "财务小组件"),
                    freeValue: .feature(false),
                    plusValue: .feature(true)
                ),
                .init(
                    icon: "shuffle",
                    name: String(localized: "随机漫步小组件"),
                    freeValue: .feature(false),
                    plusValue: .feature(true)
                ),
                .init(
                    icon: "pause.circle",
                    name: String(localized: "习惯暂停"),
                    freeValue: .feature(false),
                    plusValue: .feature(true)
                ),
                .init(
                    icon: "arrow.uturn.backward.circle",
                    name: String(localized: "习惯补签"),
                    freeValue: .text(String(localized: "限次")),
                    plusValue: .text(String(localized: "无限次"))
                ),
            ]
        ),
    ]

    /// 扁平化列表，兼容既有调用方
    static var all: [HoloPlusBenefit] {
        groups.flatMap(\.items)
    }
}

// MARK: - 对比表视图

/// 免费 vs Plus 三列对比表。纸底无卡、0.5pt 细线分组，只读展示不含购买逻辑。
struct HoloPlusBenefitComparisonTable: View {
    /// 高亮「当前方案」所在列，nil 表示不标记。
    var currentTierHighlight: Tier? = nil

    enum Tier {
        case free
        case plus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            HoloHairlineDivider()

            ForEach(Array(HoloPlusBenefits.groups.enumerated()), id: \.element.id) { index, group in
                groupHeader(group.title)
                    .padding(.top, index == 0 ? 12 : 20)

                ForEach(group.items) { benefit in
                    benefitRow(benefit)
                    HoloHairlineDivider()
                }
            }
        }
    }

    // MARK: 表头

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("能力")
                .font(.holoLabel)
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            tierHeader(title: String(localized: "免费版"), tier: .free)
                .frame(width: 78)

            tierHeader(title: "Plus", tier: .plus)
                .frame(width: 88, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func tierHeader(title: String, tier: Tier) -> some View {
        VStack(alignment: tier == .plus ? .trailing : .center, spacing: 3) {
            Text(title)
                .font(tier == .plus ? .system(size: 14, weight: .bold) : .holoLabel)
                .foregroundStyle(tier == .plus ? Color.holoToolAction : Color.holoToolTextSecondary)

            if currentTierHighlight == tier {
                Text("当前")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tier == .plus ? Color.holoToolOnAction : Color.holoToolTextSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        tier == .plus ? Color.holoToolAction : Color.holoToolInset,
                        in: Capsule()
                    )
            }
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.0)
            .foregroundStyle(Color.holoToolTextSecondary)
            .padding(.bottom, 6)
    }

    // MARK: 数据行

    private func benefitRow(_ benefit: HoloPlusBenefit) -> some View {
        HStack(spacing: 0) {
            Text(benefit.name)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            valueCell(benefit.freeValue, isPlus: false)
                .frame(width: 78)

            valueCell(benefit.plusValue, isPlus: true)
                .frame(width: 88, alignment: .trailing)
        }
        .frame(minHeight: 44)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func valueCell(_ value: HoloPlusBenefit.Value, isPlus: Bool) -> some View {
        switch value {
        case .text(let text):
            Text(text)
                .font(.system(size: 13.5, weight: isPlus ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isPlus ? Color.holoToolAction : Color.holoToolTextSecondary)
                .multilineTextAlignment(isPlus ? .trailing : .center)
                .fixedSize(horizontal: false, vertical: true)
        case .feature(let enabled):
            if enabled {
                Text("解锁")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.holoToolAction)
            } else {
                Text("—")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.45))
            }
        }
    }
}

// MARK: - 完整对比页（付费墙入口用）

/// 纯展示的完整权益对比页，由付费墙「查看全部权益对比」以 sheet 形式打开。
struct HoloPlusComparisonView: View {
    @ObservedObject private var entitlementState = HoloEntitlementState.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    Text("免费版与 Plus 完整对比")
                        .font(.holoEditorialSerif(size: 22, bold: true))
                        .foregroundStyle(Color.holoToolText)

                    HoloPlusBenefitComparisonTable(
                        currentTierHighlight: entitlementState.isPlusActive ? .plus : .free
                    )

                    Text("日常记账、待办、想法与习惯打卡永久免费，你的个人记录始终归你所有。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.vertical, HoloSpacing.lg)
            }
            .background(Color.holoToolBackground.ignoresSafeArea())
            .navigationTitle("权益对比")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

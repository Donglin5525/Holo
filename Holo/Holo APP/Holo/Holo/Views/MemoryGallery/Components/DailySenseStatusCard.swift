//  DailySenseStatusCard.swift
//  Holo
//
//  每日状态卡片（v2）
//  收起态：状态图标 + 标题 + 彩色圆点行
//  展开态：竖线圆点时间线
//

import SwiftUI

struct DailySenseStatusCard: View {

    let snapshot: DailySenseSnapshot

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // 收起态（始终显示）
            collapsedView
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                }

            // 展开态
            if isExpanded {
                expandedView
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(stateColor.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Collapsed

    private var collapsedView: some View {
        HStack(spacing: HoloSpacing.md) {
            // 状态图标
            Image(systemName: stateIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(stateColor)

            // 状态标题
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.stateTitle)
                    .font(.holoCaption)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)

                if !snapshot.tags.isEmpty {
                    Text(snapshot.tags.map(\.displayName).joined(separator: " · "))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // 彩色圆点行
            HStack(spacing: 4) {
                ForEach(snapshot.signals, id: \.dimension) { signal in
                    Circle()
                        .fill(colorForLevel(signal.level))
                        .frame(width: 8, height: 8)
                }
            }

            // 展开/收起箭头
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.holoTextPlaceholder)
        }
    }

    // MARK: - Expanded

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .background(Color.holoBorder.opacity(0.3))
                .padding(.top, HoloSpacing.sm)
                .padding(.bottom, HoloSpacing.xs)

            // 竖线圆点时间线
            VStack(alignment: .leading, spacing: 0) {
                if !snapshot.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snapshot.tags, id: \.self) { tag in
                            Text(tag.safeSummary)
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, HoloSpacing.xs)
                }

                ForEach(Array(snapshot.signals.enumerated()), id: \.element.dimension) { index, signal in
                    HStack(spacing: HoloSpacing.sm) {
                        // 圆点 + 竖线
                        signalDot(signal: signal, isLast: index == snapshot.signals.count - 1)
                            .frame(width: 16)

                        // 维度名称
                        Text(signal.dimension.displayName)
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 28, alignment: .leading)

                        // 信号文案
                        Text(signal.text)
                            .font(.holoTinyLabel)
                            .foregroundColor(colorForLevel(signal.level))
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.vertical, 5)
                }
            }
            .padding(.leading, HoloSpacing.xs)
        }
    }

    // MARK: - Signal Dot with Timeline Line

    @ViewBuilder
    private func signalDot(signal: DailySenseSignal, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(colorForLevel(signal.level))
                .frame(width: 8, height: 8)

            if !isLast {
                Rectangle()
                    .fill(Color.holoBorder.opacity(0.2))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Style Helpers

    private var stateColor: Color {
        switch snapshot.state {
        case .stable: return .holoSuccess
        case .atRisk: return .orange
        case .recovering: return .holoPrimary
        }
    }

    private var stateIcon: String {
        switch snapshot.state {
        case .stable: return "checkmark.circle.fill"
        case .atRisk: return "exclamationmark.triangle.fill"
        case .recovering: return "arrow.up.circle.fill"
        }
    }

    private func colorForLevel(_ level: SignalLevel) -> Color {
        switch level {
        case .normal: return .holoSuccess
        case .warning: return .orange
        case .critical: return .holoError
        }
    }
}

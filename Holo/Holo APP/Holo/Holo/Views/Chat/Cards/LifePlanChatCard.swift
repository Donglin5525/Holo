//
//  LifePlanChatCard.swift
//  Holo
//
//  每周计划卡（消息流）：周期头 → 3 个优先结果（带 whyNow）→ 行动卡列表（实时状态）。
//  快照从台账实时读取（非生成时刻快照）；过期卡置灰、可转手动创建（确认页内）。
//

import SwiftUI

struct LifePlanChatCard: View {
    let snapshot: LifePlanSnapshot
    var canUndo: Bool = false
    let onOpenReview: () -> Void
    let onUndo: () -> Void

    private var statusLabel: (text: String, color: Color) {
        switch snapshot.status {
        case "active": return ("本周进行中", .holoPrimary)
        case "superseded": return ("已有更新版", .holoTextSecondary)
        case "completed": return ("已结束", .holoTextSecondary)
        default: return (snapshot.status, .holoTextSecondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            header
            if let constraint = snapshot.constraintSummary, !constraint.isEmpty {
                Text(constraint)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            prioritiesSection
            actionsSection
            footer
        }
        .padding(HoloSpacing.md)
        .background(Color.holoBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoPrimary.opacity(0.25), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.holoPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text("本周重点")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                Text(periodText)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            Spacer()
            Text(statusLabel.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(statusLabel.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusLabel.color.opacity(0.1))
                .clipShape(Capsule())
        }
    }

    private var periodText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return "\(formatter.string(from: snapshot.periodStart)) – \(formatter.string(from: snapshot.periodEnd))"
    }

    private var prioritiesSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            ForEach(snapshot.priorities) { priority in
                HStack(alignment: .top, spacing: HoloSpacing.sm) {
                    Text("\(priority.priorityRank)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 18, height: 18)
                        .background(Color.holoPrimary.opacity(0.12))
                        .clipShape(Circle())
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(priority.outcome)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoTextPrimary)
                        Text(priority.whyNow)
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            HStack(spacing: 4) {
                Text("行动卡")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                Text("\(snapshot.acceptedActionCount)/\(snapshot.actions.count)")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }
            ForEach(snapshot.actions) { action in
                actionRow(action)
            }
        }
    }

    private func actionRow(_ action: LifePlanActionSnapshot) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: action.type == "habit" ? "arrow.triangle.2.circlepath" : "checkmark.square")
                .font(.system(size: 13))
                .foregroundColor(actionDisplay(action).color)
            Text(action.payload.displayTitle)
                .font(.system(size: 13))
                .foregroundColor(actionDisplay(action).color)
                .strikethrough(action.status == "expired" || action.status == "rejected")
            Spacer()
            Text(actionDisplay(action).label)
                .font(.system(size: 11))
                .foregroundColor(actionDisplay(action).color)
        }
        .padding(.vertical, 3)
        .opacity(action.status == "expired" ? 0.55 : 1)
    }

    private func actionDisplay(_ action: LifePlanActionSnapshot) -> (label: String, color: Color) {
        switch action.status {
        case "proposed": return ("待确认", .holoPrimary)
        case "accepted": return ("已加入", .holoSuccess)
        case "completed": return ("已完成", .holoSuccess)
        case "rejected": return ("已拒绝", .holoTextSecondary)
        case "expired": return ("已过期", .holoTextSecondary)
        default: return (action.status, .holoTextSecondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            if snapshot.proposedActionCount > 0 {
                Button(action: onOpenReview) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("确认本周行动（\(snapshot.proposedActionCount) 张待确认）")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.holoPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .buttonStyle(.plain)
            }
            if canUndo {
                Button(action: onUndo) {
                    Label("撤销刚才的确认", systemImage: "arrow.uturn.backward")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

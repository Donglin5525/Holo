//
//  InstallmentImportSection.swift
//  Holo
//
//  导入预览页的分期识别区块 — 展示自动识别的分期组、待确认的疑似组、未归组提示
//

import SwiftUI

// MARK: - InstallmentImportSection

/// 分期识别区块（扫描检出分期组或疑似组时显示）
struct InstallmentImportSection: View {

    @ObservedObject var viewModel: ImportPreviewViewModel
    let info: InstallmentScanInfo

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    /// 待用户判断的疑似组（未确认、未忽略）
    private var pendingSuspected: [InstallmentImportRecognizer.SuspectedGroup] {
        info.suspected.filter {
            !viewModel.confirmedSuspectedIds.contains($0.id)
                && !viewModel.ignoredSuspectedIds.contains($0.id)
        }
    }

    /// 已确认归组的疑似组
    private var confirmedSuspected: [InstallmentImportRecognizer.SuspectedGroup] {
        info.suspected.filter { viewModel.confirmedSuspectedIds.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoPrimary)
                Text("分期识别")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Text(String(localized: "\(info.groups.count + confirmedSuspected.count) 组"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }

            VStack(spacing: 8) {
                // 自动识别的分期组（强信号，直接生效）
                ForEach(info.groups) { group in
                    groupRow(group)
                }

                // 用户已确认的疑似组
                ForEach(confirmedSuspected) { group in
                    confirmedSuspectedRow(group)
                }

                // 待用户判断的疑似组（弱信号，不确认不生效）
                ForEach(pendingSuspected) { group in
                    suspectedRow(group)
                }

                // 带分期字样但未能归组的行（保守降级，信息保留在备注）
                if info.ungroupedSignalCount > 0 {
                    ungroupedRow
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    // MARK: - 自动识别组

    private func groupRow(_ group: InstallmentImportRecognizer.GroupSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: "¥\(group.amount)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                Text(periodLabel(group))
                    .font(.system(size: 12))
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.holoPrimary.opacity(0.1))
                    .clipShape(Capsule())
                Spacer()
                Text(String(localized: "\(group.rowCount) 笔"))
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }
            Text("\(Self.dateFormatter.string(from: group.firstDate)) - \(Self.dateFormatter.string(from: group.lastDate))")
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary)
            if group.futureCount > 0 {
                Text(String(localized: "其中 \(group.futureCount) 笔为未来期次：已保存但不计入统计，到期后自动出现在账单里"))
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func periodLabel(_ group: InstallmentImportRecognizer.GroupSummary) -> String {
        group.firstIndex == group.lastIndex
            ? String(localized: "第\(group.firstIndex)期/共\(group.total)期")
            : String(localized: "第\(group.firstIndex)-\(group.lastIndex)期/共\(group.total)期")
    }

    // MARK: - 疑似组（待确认）

    private func suspectedRow(_ group: InstallmentImportRecognizer.SuspectedGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "\(group.rows.count) 笔同金额交易按月出现，是一个分期吗？"))
                .font(.system(size: 13))
                .foregroundColor(.holoTextPrimary)
            HStack(spacing: 6) {
                Text(verbatim: "¥\(group.amount)")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                Text(group.accountName)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                Spacer()
            }
            Text("\(Self.dateFormatter.string(from: group.firstDate)) - \(Self.dateFormatter.string(from: group.lastDate))")
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.sm) {
                Button {
                    viewModel.confirmSuspectedGroup(group.id)
                } label: {
                    Text(String(localized: "归为分期"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.holoPrimary)
                        .clipShape(Capsule())
                }
                Button {
                    viewModel.ignoreSuspectedGroup(group.id)
                } label: {
                    Text(String(localized: "不是分期"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.holoBackground)
                        .clipShape(Capsule())
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Color.holoBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
    }

    // MARK: - 已确认的疑似组

    private func confirmedSuspectedRow(_ group: InstallmentImportRecognizer.SuspectedGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.green)
            Text(verbatim: "¥\(group.amount)")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.holoTextPrimary)
            Text(String(localized: "第1-\(group.rows.count)期/共\(group.rows.count)期"))
                .font(.system(size: 12))
                .foregroundColor(.holoPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.holoPrimary.opacity(0.1))
                .clipShape(Capsule())
            Spacer()
            Button {
                viewModel.ignoreSuspectedGroup(group.id)
            } label: {
                Text(String(localized: "撤销"))
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 未归组提示

    private var ungroupedRow: some View {
        Text(String(localized: "另有 \(info.ungroupedSignalCount) 笔带分期字样但无法确定归属，将按普通交易导入（分期信息保留在备注中）"))
            .font(.system(size: 11))
            .foregroundColor(.holoTextSecondary)
    }
}

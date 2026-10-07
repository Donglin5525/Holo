//
//  CloudRepullView.swift
//  Holo
//
//  「从 iCloud 重新拉取全部数据」全流程页（P2，2026-10-06）：
//  备份中 → 接收中（实时计数）→ 完成报告（前后对照）/ 失败（可恢复备份）。
//  全屏覆盖：拉取期间本机库正在重建，盖住全 App 防止产生新的本机写入。
//

import SwiftUI

struct CloudRepullView: View {
    @ObservedObject private var service = CloudRepullService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    content
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationTitle("从 iCloud 重新拉取")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if service.canDismiss {
                        Button {
                            service.dismiss()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(!service.canDismiss)  // 进行中不许下滑关页
    }

    @ViewBuilder
    private var content: some View {
        switch service.phase {
        case .idle:
            introCard
        case .backingUp:
            stepCard(
                icon: "externaldrive.badge.timemachine",
                title: String(localized: "正在备份本机数据…"),
                detail: String(localized: "备份完成后会重置本机数据库，从 iCloud 云端重新接收全部数据")
            )
        case .importing(let counts):
            importingCard(counts: counts)
        case .finished(let report):
            finishedCard(report: report)
        case .failed(let message):
            failedCard(message: message)
        }
    }

    private var introCard: some View {
        statusCard {
            Text("确认重新拉取")
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)
            Text("本机数据将以 iCloud 云端数据完整替换。开始前会自动备份本机数据，完成后可一键恢复。过程需保持网络连接，通常需要几分钟。")
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func importingCard(counts: [CloudRepullService.EntityCount]) -> some View {
        VStack(spacing: HoloSpacing.lg) {
            stepCard(
                icon: "icloud.and.arrow.down",
                title: String(localized: "正在从 iCloud 接收数据…"),
                detail: String(localized: "已接收的实时数量如下，全部到齐后会自动进入完成报告"),
                spins: true
            )

            countList(counts: counts)
        }
    }

    private func finishedCard(report: CloudRepullService.RepullReport) -> some View {
        VStack(spacing: HoloSpacing.lg) {
            statusCard {
                Label(String(localized: "拉取完成"), systemImage: "checkmark.circle.fill")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoSuccess)
                Text("以下是本次从 iCloud 接收到的数量（括号内为拉取前本机数量）。")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            countList(counts: report.after, before: report.before)

            Button {
                Task { await service.restoreBackup() }
            } label: {
                Text(service.isRestoring ? String(localized: "正在恢复本机备份…") : String(localized: "恢复拉取前的本机数据"))
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .disabled(service.isRestoring)

            Button {
                service.dismiss()
                dismiss()
            } label: {
                Text("完成")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.holoPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
        }
    }

    private func failedCard(message: String) -> some View {
        VStack(spacing: HoloSpacing.lg) {
            statusCard {
                Label(String(localized: "拉取未完成"), systemImage: "exclamationmark.triangle.fill")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoError)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !service.backupFiles.isEmpty {
                Button {
                    Task { await service.restoreBackup() }
                } label: {
                    Text(service.isRestoring ? String(localized: "正在恢复本机备份…") : String(localized: "恢复拉取前的本机数据"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.holoError)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .disabled(service.isRestoring)
            }
        }
    }

    // MARK: - 组件

    private func stepCard(icon: String, title: String, detail: String, spins: Bool = false) -> some View {
        statusCard {
            HStack(spacing: HoloSpacing.md) {
                if spins {
                    ProgressView()
                        .tint(.holoPrimary)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.holoPrimary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.holoBody)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextPrimary)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    private func statusCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            content()
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    /// 计数列表：拉取后数量为主文案；提供 before 时对照显示（括号内）
    private func countList(counts: [CloudRepullService.EntityCount], before: [CloudRepullService.EntityCount]? = nil) -> some View {
        let beforeByEntity = Dictionary(uniqueKeysWithValues: (before ?? []).map { ($0.entity, $0.count) })

        return VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("数据数量")
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            VStack(spacing: 0) {
                ForEach(Array(counts.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        Text(item.displayName)
                            .font(.system(size: 13))
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                        if let beforeCount = beforeByEntity[item.entity], beforeCount != item.count {
                            Text("\(item.count)（\(beforeCount)）")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.holoTextPrimary)
                        } else {
                            Text("\(item.count)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                    .padding(.vertical, 8)
                    if index < counts.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
    }
}

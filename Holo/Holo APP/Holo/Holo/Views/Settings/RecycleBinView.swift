//
//  RecycleBinView.swift
//  Holo
//
//  回收站（「最近删除」）：按删除事件分组展示清空批次
//
//  - 事件卡：时间 / 涉及模块 / 条数 / 剩余天数
//  - 事件详情：模块分节 + 恢复（含冲突预检）+ 立即清除
//  - 恢复预览：疑似与新数据重复的条目默认跳过，可勾选强制恢复
//

import SwiftUI

// MARK: - 回收站主页（事件列表）

struct RecycleBinView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var recycleBin = RecycleBinService.shared

    @State private var selectedBatch: RecycleBinBatchInfo?
    @State private var showPurgeAllAlert = false
    @State private var isPurgingAll = false

    var body: some View {
        NavigationView {
            Group {
                if recycleBin.batches.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: HoloSpacing.md) {
                            ForEach(recycleBin.batches) { batch in
                                NavigationLink {
                                    RecycleBinBatchDetailView(batch: batch)
                                } label: {
                                    batchCard(batch)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(HoloSpacing.lg)
                    }
                }
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("最近删除")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if !recycleBin.batches.isEmpty {
                        Button("清空回收站") { showPurgeAllAlert = true }
                            .foregroundColor(.holoError)
                    }
                }
            }
        }
        .task {
            await recycleBin.reloadBatches()
        }
        .alert("清空回收站", isPresented: $showPurgeAllAlert) {
            Button("取消", role: .cancel) {}
            Button("彻底删除", role: .destructive) {
                Task { await purgeAll() }
            }
        } message: {
            Text("回收站内所有数据将被立即彻底删除，无法恢复。")
        }
    }

    // MARK: - 子视图

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "trash.slash")
                .font(.system(size: 40))
                .foregroundColor(.holoTextSecondary)
            Text("回收站是空的")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            Text("清空模块数据后，30 天内可在这里恢复")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func batchCard(_ batch: RecycleBinBatchInfo) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16))
                    .foregroundColor(.holoPrimary)

                Text(batch.createdAt.formatted(.dateTime.year().month().day().hour().minute()))
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Text("还剩 \(batch.daysRemaining) 天")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(batch.daysRemaining <= 3 ? .holoError : .holoTextSecondary)
            }

            Text(batch.summary ?? (batch.isGlobalScope ? "清空所有数据" : "清空数据"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.sm) {
                ForEach(batch.modules) { module in
                    moduleChip(module, count: batch.moduleCounts[module] ?? 0)
                }
                Spacer()
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .contentShape(Rectangle())
    }

    private func moduleChip(_ module: RecycleBinModule, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(module.displayName)
            Text("·\(count)")
                .foregroundColor(.holoTextSecondary)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.holoTextPrimary.opacity(0.8))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.holoPrimary.opacity(0.08)))
    }

    // MARK: - 逻辑

    private func purgeAll() async {
        guard !isPurgingAll else { return }
        isPurgingAll = true
        defer { isPurgingAll = false }
        try? await recycleBin.purgeAll()
        HoloToastCenter.shared.show("回收站已清空", type: .success)
    }
}

// MARK: - 事件详情

struct RecycleBinBatchDetailView: View {

    let batch: RecycleBinBatchInfo

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var recycleBin = RecycleBinService.shared

    @State private var isPreparingRestore = false
    @State private var showRestoreConfirm = false
    @State private var showPurgeAlert = false
    @State private var restorePreview: RestorePreviewReport?
    @State private var showConflictSheet = false
    @State private var isRestoring = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                infoCard

                ForEach(batch.modules) { module in
                    moduleRow(module, count: batch.moduleCounts[module] ?? 0)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundColor(.holoError)
                }

                HStack(spacing: HoloSpacing.md) {
                    restoreButton
                    purgeButton
                }
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground.ignoresSafeArea())
        .navigationTitle("删除事件")
        .navigationBarTitleDisplayMode(.inline)
        .alert("恢复数据", isPresented: $showRestoreConfirm) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .none) {
                Task { await performRestore(skipIds: []) }
            }
        } message: {
            let preview = restorePreview
            if let preview, preview.hasConflicts {
                return Text("检测到 \(preview.conflicts.count) 条疑似重复数据将跳过，其余 \(preview.restorableCount) 条将恢复。")
            }
            return Text("将恢复 \(preview?.restorableCount ?? batch.totalRemaining) 条数据到原模块。")
        }
        .alert("立即清除", isPresented: $showPurgeAlert) {
            Button("取消", role: .cancel) {}
            Button("彻底删除", role: .destructive) {
                Task { await performPurge() }
            }
        } message: {
            Text("这批数据将被立即彻底删除，无法恢复。")
        }
        .sheet(isPresented: $showConflictSheet) {
            if let preview = restorePreview, preview.hasConflicts {
                RestoreConflictSheet(batch: batch, preview: preview) { forcedIds in
                    let skip = Set(preview.conflicts.map(\.id)).subtracting(forcedIds)
                    Task {
                        await performRestore(skipIds: skip)
                    }
                }
            }
        }
    }

    // MARK: - 子视图

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text(batch.summary ?? "清空数据")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text("还剩 \(batch.daysRemaining) 天")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(batch.daysRemaining <= 3 ? .holoError : .holoTextSecondary)
            }
            Text(batch.createdAt.formatted(.dateTime.year().month().day().hour().minute()))
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private func moduleRow(_ module: RecycleBinModule, count: Int) -> some View {
        HStack {
            Text(module.displayName)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
            Spacer()
            Text("\(count) 条")
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var restoreButton: some View {
        Button {
            Task { await prepareRestore() }
        } label: {
            Group {
                if isPreparingRestore {
                    ProgressView().tint(.white)
                } else {
                    Text("恢复此批次").font(.holoBody).fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.holoPrimary)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isPreparingRestore || isRestoring)
    }

    private var purgeButton: some View {
        Button {
            showPurgeAlert = true
        } label: {
            Text("立即清除")
                .font(.holoBody)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.holoError.opacity(0.1))
                .foregroundColor(.holoError)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isRestoring)
    }

    // MARK: - 逻辑

    private func prepareRestore() async {
        guard !isPreparingRestore else { return }
        isPreparingRestore = true
        errorMessage = nil
        defer { isPreparingRestore = false }

        do {
            let preview = try await recycleBin.restorePreview(batchId: batch.id)
            restorePreview = preview
            if preview.hasConflicts {
                // 弹冲突明细，由用户决定跳过哪些
                showConflictSheet = true
            } else {
                showRestoreConfirm = true
            }
        } catch {
            errorMessage = "检查失败：\(error.localizedDescription)"
        }
    }

    private func performRestore(skipIds: Set<UUID>) async {
        guard !isRestoring else { return }
        isRestoring = true
        errorMessage = nil
        defer { isRestoring = false }

        do {
            let outcome = try await recycleBin.restoreBatch(batchId: batch.id, skipConflictIds: skipIds)
            var message = "已恢复 \(outcome.restored) 条"
            if outcome.skippedConflicts > 0 { message += "，跳过 \(outcome.skippedConflicts) 条重复" }
            if outcome.linkedRestored > 0 { message += "，连带恢复 \(outcome.linkedRestored) 条关联数据" }
            HoloToastCenter.shared.show(message, type: .success)
            dismiss()
        } catch {
            errorMessage = "恢复失败：\(error.localizedDescription)"
        }
    }

    private func performPurge() async {
        do {
            try await recycleBin.purgeBatch(batch.id)
            HoloToastCenter.shared.show("已彻底删除", type: .info)
            dismiss()
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 恢复冲突明细

/// 疑似重复条目明细：默认全部跳过，勾选后强制恢复
struct RestoreConflictSheet: View {

    let batch: RecycleBinBatchInfo
    let preview: RestorePreviewReport
    /// 返回用户勾选「仍然恢复」的冲突条目 id
    let onForceRestore: (Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var forcedIds: Set<UUID> = []
    @State private var isRestoring = false

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    Text("检测到 \(preview.conflicts.count) 条数据与清空后新产生的数据疑似重复（同日同额/同名等）。默认跳过这些条目、保留现有数据；如确认要恢复，请单独勾选。")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if preview.restorableCount > 0 {
                        HStack {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(.holoPrimary)
                            Text("\(preview.restorableCount) 条无冲突，将直接恢复")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.holoTextPrimary)
                        }
                        .padding(HoloSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.holoCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    }

                    Text("疑似重复（默认跳过）")
                        .font(.holoBody)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextPrimary)

                    ForEach(preview.conflicts) { conflict in
                        conflictRow(conflict)
                    }
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("恢复预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    isRestoring = true
                    onForceRestore(forcedIds)
                    dismiss()
                } label: {
                    Group {
                        if isRestoring {
                            ProgressView().tint(.white)
                        } else {
                            Text("跳过重复，恢复其余")
                                .font(.holoBody)
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.holoPrimary)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(HoloSpacing.lg)
                .background(Color.holoBackground)
            }
        }
    }

    private func conflictRow(_ conflict: RestoreConflictItem) -> some View {
        let isForced = forcedIds.contains(conflict.id)
        return Button {
            if isForced {
                forcedIds.remove(conflict.id)
            } else {
                forcedIds.insert(conflict.id)
            }
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: isForced ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundColor(isForced ? .holoPrimary : .holoTextSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(conflict.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                    Text("\(conflict.detail) · \(conflict.existingDetail)")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(2)
                }

                Spacer()

                Text(isForced ? "将恢复" : "跳过")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isForced ? .holoPrimary : .holoTextSecondary)
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

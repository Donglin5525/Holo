//
//  DataManagementView.swift
//  Holo
//
//  设置 → 数据管理 子页
//
//  - 各模块数据概览
//  - 最近删除（回收站统一入口，D5：仅此处）
//  - 清空所有数据（专用确认页 + 输入「清空」二字，D3；不注销账号，与「删除账号」区别）
//

import SwiftUI

struct DataManagementView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var moduleCounts: [RecycleBinModule: Int] = [:]
    @State private var isLoadingCounts = true
    @State private var showRecycleBin = false
    @State private var showClearAllConfirm = false
    @State private var recycleBatchCount = 0

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    overviewSection
                    recycleBinSection
                    clearAllSection
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("数据管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            await reloadData()
        }
        .sheet(isPresented: $showRecycleBin, onDismiss: {
            Task { await reloadData() }
        }) {
            RecycleBinView()
        }
        .sheet(isPresented: $showClearAllConfirm, onDismiss: {
            Task { await reloadData() }
        }) {
            ClearAllDataConfirmSheet(moduleCounts: moduleCounts)
        }
    }

    // MARK: - 子视图

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)
                Text("数据概览")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            if isLoadingCounts {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 20)
                    Spacer()
                }
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            } else {
                VStack(spacing: 0) {
                    ForEach(RecycleBinModule.allCases) { module in
                        moduleCountRow(module)
                    }
                }
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
        }
    }

    private func moduleCountRow(_ module: RecycleBinModule) -> some View {
        HStack {
            Text(module.displayName)
                .font(.system(size: 15))
                .foregroundColor(.holoTextPrimary)
            Spacer()
            Text("\(moduleCounts[module] ?? 0) 条")
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 11)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.holoBorder.opacity(0.5)),
            alignment: .bottom
        )
    }

    private var recycleBinSection: some View {
        Button {
            showRecycleBin = true
        } label: {
            HStack(spacing: HoloSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(Color.holoPrimary.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.holoPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("最近删除")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text("清空的数据保留 30 天，期间可恢复")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                if recycleBatchCount > 0 {
                    Text("\(recycleBatchCount)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.holoPrimary.opacity(0.12)))
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var clearAllSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "trash")
                    .font(.system(size: 18))
                    .foregroundColor(.holoError)
                Text("危险操作")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            Button {
                showClearAllConfirm = true
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(Color.holoError.opacity(0.1))
                            .frame(width: 40, height: 40)
                        Image(systemName: "trash.slash")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.holoError)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("清空所有数据")
                            .font(.holoBody)
                            .foregroundColor(.holoError)
                        Text("全部模块数据进入 30 天回收站；不影响账号、订阅与设置")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                }
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Text("与「删除账号」的区别：清空所有数据不注销账号，登录状态、Holo Plus 订阅与偏好设置都会保留；健康数据来自系统健康 App，不受影响。")
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 逻辑

    private func reloadData() async {
        moduleCounts = await RecycleBinService.shared.moduleDataCounts()
        await RecycleBinService.shared.reloadBatches()
        recycleBatchCount = RecycleBinService.shared.batches.count
        isLoadingCounts = false
    }
}

// MARK: - 清空所有数据确认页（输入「清空」二次确认，D3）

struct ClearAllDataConfirmSheet: View {

    let moduleCounts: [RecycleBinModule: Int]

    @Environment(\.dismiss) private var dismiss
    @State private var confirmText = ""
    @State private var isClearing = false
    @State private var errorMessage: String?

    private var totalAffected: Int {
        moduleCounts.values.reduce(0, +)
    }

    private var isTextConfirmed: Bool {
        confirmText.trimmingCharacters(in: .whitespacesAndNewlines) == "清空"
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    warningCard
                    affectedListCard
                    inputCard

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.holoError)
                    }

                    confirmButton
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("清空所有数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    // MARK: - 子视图

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                Text("此操作影响全部模块")
                    .font(.holoBody)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.holoError)

            Text("以下数据将全部进入 30 天回收站，到期自动彻底删除。账号、订阅、登录状态与偏好设置不受影响；健康数据不受影响。")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoError.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var affectedListCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("将清空的数据（共 \(totalAffected) 条）")
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            VStack(spacing: 0) {
                ForEach(RecycleBinModule.allCases) { module in
                    HStack {
                        Text(module.displayName)
                            .font(.system(size: 14))
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                        Text("\(moduleCounts[module] ?? 0) 条")
                            .font(.system(size: 13))
                            .foregroundColor(.holoTextSecondary)
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, 10)
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("请输入「清空」以确认")
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            TextField("清空", text: $confirmText)
                .font(.holoBody)
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(isTextConfirmed ? Color.holoPrimary.opacity(0.6) : Color.holoBorder.opacity(0.6), lineWidth: 1)
                )
                .autocorrectionDisabled()
        }
    }

    private var confirmButton: some View {
        Button {
            Task { await performClear() }
        } label: {
            Group {
                if isClearing {
                    ProgressView().tint(.white)
                } else {
                    Text("确认清空所有数据")
                        .font(.holoBody)
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isTextConfirmed ? Color.holoError : Color.holoTextSecondary.opacity(0.4))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isTextConfirmed || isClearing)
    }

    // MARK: - 逻辑

    private func performClear() async {
        guard isTextConfirmed, !isClearing else { return }
        isClearing = true
        errorMessage = nil
        defer { isClearing = false }

        do {
            _ = try await RecycleBinService.shared.performClear(.init(
                modules: RecycleBinModule.globalClearModules,
                financeScope: .all,
                summary: "清空所有数据"
            ))
            HoloToastCenter.shared.show("已清空，30 天内可在设置-数据管理恢复", type: .success)
            dismiss()
        } catch {
            errorMessage = "清空失败：\(error.localizedDescription)"
        }
    }
}

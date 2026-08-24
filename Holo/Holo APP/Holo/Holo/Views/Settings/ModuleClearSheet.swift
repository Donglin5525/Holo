//
//  ModuleClearSheet.swift
//  Holo
//
//  模块级「清空数据」确认页（财务/想法/任务/习惯共用）
//
//  - 财务显示范围选择（东林拍板 D1：仅清交易 / 全部）
//  - 其余模块直接展示影响条数
//  - 确认后走 RecycleBinService 进 30 天回收站（设置 → 数据管理 → 最近删除 可恢复）
//

import SwiftUI

struct ModuleClearSheet: View {

    enum Module: String, Identifiable {
        case finance
        case thought
        case task
        case habit

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .finance: return "财务"
            case .thought: return "想法"
            case .task: return "任务"
            case .habit: return "习惯"
            }
        }

        var recycleModule: RecycleBinModule {
            switch self {
            case .finance: return .finance
            case .thought: return .thought
            case .task: return .task
            case .habit: return .habit
            }
        }

        var icon: String {
            switch self {
            case .finance: return "yen.circle"
            case .thought: return "lightbulb"
            case .task: return "checklist"
            case .habit: return "flame"
            }
        }
    }

    let module: Module
    var onCompleted: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var isPreparing = true
    @State private var transactionOnlyCount = 0
    @State private var financeAllCount = 0
    @State private var moduleCount = 0
    @State private var financeScope: FinanceClearScope = .transactionsOnly
    @State private var isClearing = false
    @State private var showConfirmAlert = false
    @State private var errorMessage: String?

    private var affectedCount: Int {
        guard module == .finance else { return moduleCount }
        return financeScope == .transactionsOnly ? transactionOnlyCount : financeAllCount
    }

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    headerCard

                    if module == .finance {
                        financeScopeSection
                    } else {
                        impactCard
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.holoError)
                    }

                    clearButton
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("清空\(module.displayName)数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .task {
            await loadPreview()
        }
        .alert("确认清空", isPresented: $showConfirmAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                Task { await performClear() }
            }
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: - 子视图

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: module.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.holoError)
                Text("将清空\(module.displayName)模块的全部记录")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
            }
            Text("清空后的数据会保留 30 天，期间可在 设置 → 数据管理 → 最近删除 中恢复；到期后自动彻底删除。")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var financeScopeSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("选择清空范围")
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            VStack(spacing: HoloSpacing.sm) {
                ForEach(FinanceClearScope.allCases) { scope in
                    scopeOption(scope)
                }
            }
        }
    }

    private func scopeOption(_ scope: FinanceClearScope) -> some View {
        let isSelected = financeScope == scope
        return Button {
            financeScope = scope
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(scope.displayName)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text(scopeSubtitle(scope))
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if isPreparing {
                    ProgressView()
                } else {
                    Text("\(scopeCount(scope)) 条")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(isSelected ? Color.holoPrimary.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func scopeSubtitle(_ scope: FinanceClearScope) -> String {
        switch scope {
        case .transactionsOnly: return "保留账户、分类、预算与固定支出设置"
        case .all: return "交易、账户、分类、预算、固定支出全部清空"
        }
    }

    private func scopeCount(_ scope: FinanceClearScope) -> Int {
        scope == .transactionsOnly ? transactionOnlyCount : financeAllCount
    }

    private var impactCard: some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: "number.circle")
                .font(.system(size: 18))
                .foregroundColor(.holoPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text("影响范围")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                if isPreparing {
                    Text("正在统计…")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                } else {
                    Text("将清空 \(affectedCount) 条\(module.displayName)记录")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            Spacer()
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var clearButton: some View {
        Button {
            showConfirmAlert = true
        } label: {
            Group {
                if isClearing {
                    ProgressView().tint(.white)
                } else {
                    Text("清空\(module.displayName)数据")
                        .font(.holoBody)
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(affectedCount == 0 ? Color.holoTextSecondary.opacity(0.4) : Color.holoError)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isClearing || isPreparing || affectedCount == 0)
    }

    // MARK: - 逻辑

    private var confirmMessage: String {
        if module == .finance {
            return "将清空「\(financeScope.displayName)」共 \(affectedCount) 条记录。清空后 30 天内可在 设置 → 数据管理 → 最近删除 恢复。"
        }
        return "将清空 \(affectedCount) 条\(module.displayName)记录。清空后 30 天内可在 设置 → 数据管理 → 最近删除 恢复。"
    }

    private func loadPreview() async {
        if module == .finance {
            let only = await RecycleBinService.shared.previewCounts(for: [.finance], financeScope: .transactionsOnly)
            let all = await RecycleBinService.shared.previewCounts(for: [.finance], financeScope: .all)
            transactionOnlyCount = only[.finance] ?? 0
            financeAllCount = all[.finance] ?? 0
        } else {
            let counts = await RecycleBinService.shared.previewCounts(for: [module.recycleModule], financeScope: nil)
            moduleCount = counts[module.recycleModule] ?? 0
        }
        isPreparing = false
    }

    private func performClear() async {
        guard !isClearing else { return }
        isClearing = true
        errorMessage = nil
        defer { isClearing = false }

        do {
            _ = try await RecycleBinService.shared.performClear(.init(
                modules: [module.recycleModule],
                financeScope: module == .finance ? financeScope : nil,
                summary: nil
            ))
            HoloToastCenter.shared.show("已清空，30 天内可在设置-数据管理恢复", type: .success)
            onCompleted?()
            dismiss()
        } catch {
            errorMessage = "清空失败：\(error.localizedDescription)"
        }
    }
}

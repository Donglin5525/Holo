//
//  ImportResultSheet.swift
//  Holo
//
//  导入结果弹窗 — 展示导入统计 + 24 小时撤回入口
//

import SwiftUI

struct ImportResultSheet: View {
    @Environment(\.dismiss) var dismiss

    let result: BatchImportResult

    /// 撤回回调
    let onUndo: (() -> Void)?

    @State private var showUndoConfirm = false
    @State private var undoError: String?
    @State private var showUndoError = false

    init(result: BatchImportResult, onUndo: (() -> Void)? = nil) {
        self.result = result
        self.onUndo = onUndo
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 拖动指示条
                Capsule()
                    .fill(Color.holoTextSecondary.opacity(0.3))
                    .frame(width: 36, height: 5)
                    .padding(.top, 12)
                    .padding(.bottom, 16)

                VStack(spacing: HoloSpacing.lg) {
                    // 成功图标
                    VStack(spacing: 8) {
                        Image(systemName: result.isAllSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(result.isAllSuccess ? .holoSuccess : .orange)

                        Text(result.isAllSuccess ? "导入完成" : "导入完成（有提示）")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.holoTextPrimary)
                    }

                    // 统计列表
                    VStack(spacing: 12) {
                        resultRow(
                            icon: "checkmark",
                            color: .holoSuccess,
                            label: "成功导入",
                            value: "\(result.successCount) 条"
                        )

                        if result.skippedDuplicateCount > 0 {
                            resultRow(
                                icon: "arrow.triangle.2.circlepath",
                                color: .holoPrimary,
                                label: "跳过重复",
                                value: "\(result.skippedDuplicateCount) 条"
                            )
                        }

                        if !result.failedItems.isEmpty {
                            resultRow(
                                icon: "xmark",
                                color: .red,
                                label: "导入失败",
                                value: "\(result.failedItems.count) 条"
                            )
                        }

                        if result.newCategoriesCount > 0 {
                            resultRow(
                                icon: "folder.badge.plus",
                                color: .blue,
                                label: "新建分类",
                                value: "\(result.newCategoriesCount) 个"
                            )
                        }

                        if result.newAccountsCount > 0 {
                            resultRow(
                                icon: "creditcard.badge.plus",
                                color: .orange,
                                label: "新建账户",
                                value: "\(result.newAccountsCount) 个"
                            )
                        }

                        // 存盘失败提示
                        if !result.saveSucceeded {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("部分数据可能未保存成功，建议重新导入")
                                    .font(.system(size: 13))
                                    .foregroundColor(.red)
                            }
                            .padding(12)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        }
                    }
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                    // 失败明细（最多 5 条）
                    if !result.failedItems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("失败明细")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.holoTextSecondary)
                            ForEach(Array(result.failedItems.prefix(5).enumerated()), id: \.offset) { _, failure in
                                Text("第 \(failure.index) 行：\(failure.error)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.holoTextSecondary)
                            }
                            if result.failedItems.count > 5 {
                                Text("...还有 \(result.failedItems.count - 5) 条")
                                    .font(.system(size: 11))
                                    .foregroundColor(.holoTextSecondary)
                            }
                        }
                        .padding(HoloSpacing.md)
                        .background(Color.orange.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    }

                    Spacer()

                    // 撤回入口（仅成功导入且在 24h 内）
                    if onUndo != nil, result.batchId != nil, result.successCount > 0 {
                        Button {
                            showUndoConfirm = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                Text("撤回此次导入")
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                        }
                    }

                    // 完成按钮
                    Button {
                        dismiss()
                    } label: {
                        Text("完成")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.holoPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.bottom, HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .alert("撤回此次导入？", isPresented: $showUndoConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认撤回", role: .destructive) {
                onUndo?()
                dismiss()
            }
        } message: {
            Text("将删除本次导入的 \(result.successCount) 条交易，以及自动创建且未被引用的分类和账户。导入后被你编辑过的交易不会被删除。")
        }
    }

    private func resultRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(.holoTextSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.holoTextPrimary)
        }
    }
}

//
//  ImportPreviewSheet.swift
//  Holo
//
//  导入预览弹窗 — 显示解析结果、字段映射、分类匹配、解析警告
//  用户确认后执行批量导入
//

import SwiftUI

// MARK: - ImportPreviewSheet

/// 导入预览弹窗
struct ImportPreviewSheet: View {

    @Environment(\.dismiss) var dismiss
    @StateObject private var viewModel: ImportPreviewViewModel

    init(fileURL: URL, onComplete: @escaping (BatchImportResult) -> Void) {
        _viewModel = StateObject(wrappedValue: ImportPreviewViewModel(
            fileURL: fileURL,
            onComplete: onComplete,
            dismiss: { @MainActor in /* placeholder, replaced by environment */ }
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部信息栏
                headerSection

                Divider()

                if viewModel.isParsing {
                    VStack(spacing: HoloSpacing.md) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("正在扫描文件...")
                            .font(.system(size: 14))
                            .foregroundColor(.holoTextSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let summary = viewModel.scanSummary {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: HoloSpacing.lg) {
                        // 检测结果卡片
                        detectionCard(summary)

                        // 账单区块（AI 匹配 / 账户映射 / 疑似重复；仅账单文件显示）
                        BillImportSection(viewModel: viewModel)

                        // 字段映射（可点击编辑）
                        mappingSection(summary)

                        // 解析警告（blocking + advisory）
                        if !viewModel.parseWarnings.isEmpty {
                            parseWarningSection
                        }

                        // 分类导入计划
                        categoryMatchSection

                        // 数据预览（前 5 行）
                        previewSection(summary)

                        // 解析错误
                        if !viewModel.topFailures.isEmpty {
                            warningSection
                        }
                    }
                    .padding(HoloSpacing.lg)
                }
                } else {
                    VStack(spacing: HoloSpacing.md) {
                        ProgressView()
                        Text("准备中...")
                            .font(.system(size: 14))
                            .foregroundColor(.holoTextSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 底部按钮
                bottomActions
            }
            .background(Color.holoBackground)
            .navigationBarHidden(true)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            viewModel.performScan()
        }
        .swipeBackToDismiss { dismiss() }
        .sheet(isPresented: $viewModel.showFieldMappingEditor) {
            if let summary = viewModel.scanSummary {
                FieldMappingEditor(
                    headers: summary.headers,
                    currentMapping: viewModel.fieldMapping,
                    onSave: { mapping in
                        viewModel.updateFieldMapping(mapping)
                        viewModel.showFieldMappingEditor = false
                    },
                    onCancel: {
                        viewModel.showFieldMappingEditor = false
                    }
                )
            }
        }
    }

    // MARK: - 顶部信息栏

    private var headerSection: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.holoBackground)
                    .clipShape(Circle())
            }

            Spacer()

            Text("导入预览")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
    }

    // MARK: - 检测结果

    private func detectionCard(_ summary: ImportScanSummary) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoPrimary)
                Text("检测结果")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }

            VStack(spacing: 8) {
                infoRow(label: "文件名", value: summary.fileName)
                infoRow(label: "识别格式", value: summary.detectedTemplate.rawValue)
                infoRow(label: "总行数", value: "\(summary.totalRows) 条记录")
                infoRow(label: "可导入", value: "\(summary.parseableCount) 条")
                let newCategoryCount = viewModel.categoryImportPlan.primaryCategoriesToCreate.count
                    + viewModel.categoryImportPlan.subCategoriesToCreate.count
                if newCategoryCount > 0 {
                    infoRow(label: "将新建科目", value: "\(newCategoryCount) 个")
                }
                if summary.failedCount > 0 {
                    infoRow(label: "跳过", value: "\(summary.failedCount) 条（格式异常）")
                }
                let blockedCount = viewModel.blockingWarnings.filter { $0.isBlocking }.count
                if blockedCount > 0 {
                    infoRow(label: "待确认", value: "\(blockedCount) 条（日期解析失败）")
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    /// 信息行
    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.holoTextPrimary)
        }
    }

    // MARK: - 字段映射

    private func mappingSection(_ summary: ImportScanSummary) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoPrimary)
                Text("字段映射")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Button {
                    viewModel.showFieldMappingEditor = true
                } label: {
                    Text("编辑")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoPrimary)
                }
            }

            VStack(spacing: 6) {
                mappingRow("日期", index: viewModel.fieldMapping.dateIndex, headers: summary.headers)
                mappingRow("类型", index: viewModel.fieldMapping.typeIndex, headers: summary.headers)
                mappingRow("金额", index: viewModel.fieldMapping.amountIndex, headers: summary.headers)
                mappingRow("一级分类", index: viewModel.fieldMapping.primaryCategoryIndex, headers: summary.headers)
                mappingRow("二级分类", index: viewModel.fieldMapping.subCategoryIndex, headers: summary.headers)
                mappingRow("账户", index: viewModel.fieldMapping.accountIndex, headers: summary.headers)
                mappingRow("备注", index: viewModel.fieldMapping.noteIndex, headers: summary.headers)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    /// 映射行：HOLO 字段 → CSV 列名
    private func mappingRow(_ holoField: String, index: Int?, headers: [String]) -> some View {
        HStack {
            Text(holoField)
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 60, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 10))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            if let idx = index, idx < headers.count {
                Text(headers[idx])
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.holoPrimary.opacity(0.08))
                    .clipShape(Capsule())
            } else {
                Text("未映射")
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary.opacity(0.5))
                    .italic()
            }

            Spacer()
        }
    }

    // MARK: - 解析警告

    private var parseWarningSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            ForEach($viewModel.parseWarnings) { $warning in
                HStack(spacing: 8) {
                    Image(systemName: warning.isBlocking ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.system(size: 14))
                        .foregroundColor(warning.isBlocking ? .red : .orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning.message)
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextPrimary)

                        if warning.isBlocking && !warning.isConfirmed {
                            Button {
                                warning.isConfirmed = true
                                viewModel.confirmAllDateFallbacks()
                            } label: {
                                Text("确认全部使用今天日期")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.holoPrimary)
                            }
                        }
                    }

                    Spacer()
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - 分类导入计划

    private var categoryMatchSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 标题
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoPrimary)
                Text("科目导入计划")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }

            // 导入统计
            HStack(spacing: HoloSpacing.md) {
                matchStatBadge(label: "已存在", count: viewModel.matchStats.exact, color: .green)
                matchStatBadge(label: "新一级", count: viewModel.categoryImportPlan.primaryCategoriesToCreate.count, color: .blue)
                matchStatBadge(label: "新二级", count: viewModel.categoryImportPlan.subCategoriesToCreate.count, color: .orange)
            }

            // 将新建的一级分类（最多展示 10 个）
            let primaries = viewModel.categoryImportPlan.primaryCategoriesToCreate.prefix(10)
            if !primaries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("将新建的一级分类")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                    ForEach(Array(primaries.enumerated()), id: \.offset) { _, desc in
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.folder.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.blue)
                            Text(desc.normalizedPrimaryName)
                                .font(.system(size: 13))
                                .foregroundColor(.holoTextPrimary)
                            Text("（\(typeLabel(desc.typeRaw))）")
                                .font(.system(size: 11))
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                }
            }

            // 将新建的二级分类（最多展示 10 个）
            let subs = viewModel.categoryImportPlan.subCategoriesToCreate.prefix(10)
            if !subs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("将新建的二级分类")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                    ForEach(Array(subs.enumerated()), id: \.offset) { _, desc in
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                            Text("\(desc.normalizedPrimaryName) / \(desc.normalizedSubName ?? "")")
                                .font(.system(size: 13))
                                .foregroundColor(.holoTextPrimary)
                        }
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    /// 匹配统计徽章
    private func matchStatBadge(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(label) \(count)")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
        }
    }

    /// 交易类型中文标签
    private func typeLabel(_ raw: String) -> String {
        TransactionType(rawValue: raw) == .income ? "收入" : "支出"
    }

    // MARK: - 数据预览

    private func previewSection(_ summary: ImportScanSummary) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "eye")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoPrimary)
                Text("数据预览（前 \(summary.sampleRows.count) 条）")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }

            // 横向可滚动的数据表
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    // 表头行
                    HStack(spacing: 0) {
                        ForEach(summary.headers.indices, id: \.self) { i in
                            Text(summary.headers[i])
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.holoTextSecondary)
                                .frame(width: 80, alignment: .leading)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 4)
                        }
                    }
                    .background(Color.holoBackground)

                    Divider()

                    // 数据行（最多 5 行）
                    ForEach(Array(summary.sampleRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 0) {
                            ForEach(row.indices, id: \.self) { j in
                                Text(row[j])
                                    .font(.system(size: 11))
                                    .foregroundColor(.holoTextPrimary)
                                    .frame(width: 80, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 4)
                                    .lineLimit(1)
                            }
                        }
                        Divider()
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    // MARK: - 警告信息

    private var warningSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.orange)
                Text("\(viewModel.failedCount) 条记录将被跳过")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.orange)
            }

            // 最多展示前 5 条错误
            ForEach(Array(viewModel.topFailures.prefix(5).enumerated()), id: \.offset) { _, failure in
                Text("第 \(failure.index) 行：\(failure.error)")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
            }

            if viewModel.topFailures.count > 5 {
                Text("...还有 \(viewModel.topFailures.count - 5) 条")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - 底部按钮

    private var bottomActions: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: HoloSpacing.md) {
                // 取消按钮
                Button { dismiss() } label: {
                    Text("取消")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.holoCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                        .overlay(
                            RoundedRectangle(cornerRadius: HoloRadius.lg)
                                .stroke(Color.holoDivider, lineWidth: 1)
                        )
                }

                // 开始导入按钮
                Button { viewModel.performImport() } label: {
                    HStack {
                        if viewModel.isImporting {
                            ProgressView()
                                .tint(.white)
                                .padding(.trailing, 4)
                        }
                        Text(viewModel.importButtonText)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(viewModel.canImport ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                }
                .disabled(!viewModel.canImport)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoCardBackground)
    }
}

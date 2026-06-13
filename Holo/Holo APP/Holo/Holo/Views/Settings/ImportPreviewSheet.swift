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

    init(previewData: ImportPreviewData, onComplete: @escaping (BatchImportResult) -> Void) {
        _viewModel = StateObject(wrappedValue: ImportPreviewViewModel(
            previewData: previewData,
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
                        Text("正在解析 \(viewModel.previewData.rows.count) 条记录...")
                            .font(.system(size: 14))
                            .foregroundColor(.holoTextSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: HoloSpacing.lg) {
                        // 检测结果卡片
                        detectionCard

                        // 字段映射（可点击编辑）
                        mappingSection

                        // 解析警告（blocking + advisory）
                        if !viewModel.parseWarnings.isEmpty {
                            parseWarningSection
                        }

                        // 分类匹配预览（可点击编辑）
                        categoryMatchSection

                        // 数据预览（前 5 行）
                        previewSection

                        // 解析错误
                        if !viewModel.parseFailures.isEmpty {
                            warningSection
                        }
                    }
                    .padding(HoloSpacing.lg)
                }
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
            // 绑定 dismiss 到 ViewModel
            viewModel.performPreParse()
        }
        .swipeBackToDismiss { dismiss() }
        .sheet(item: $viewModel.editingMatchKey) { wrapper in
            if let matchResult = viewModel.matchResult(forKey: wrapper.id) {
                CategoryMatchEditor(
                    matchResult: matchResult,
                    allCategories: viewModel.categoriesForMatch(matchResult),
                    onSelectCategory: { category in
                        viewModel.updateMatch(uniqueKey: wrapper.id, newCategory: category)
                        viewModel.editingMatchKey = nil
                    },
                    onConfirmCreateNew: {
                        viewModel.confirmCreateNew(uniqueKey: wrapper.id)
                        viewModel.editingMatchKey = nil
                    },
                    onDismiss: {
                        viewModel.editingMatchKey = nil
                    }
                )
            }
        }
        .sheet(isPresented: $viewModel.showFieldMappingEditor) {
            FieldMappingEditor(
                headers: viewModel.previewData.headers,
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

    private var detectionCard: some View {
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
                infoRow(label: "文件名", value: viewModel.previewData.fileName)
                infoRow(label: "识别格式", value: viewModel.previewData.detectedTemplate.rawValue)
                infoRow(label: "总行数", value: "\(viewModel.previewData.rows.count) 条记录")
                infoRow(label: "可导入", value: "\(viewModel.parsedItemCount) 条")
                let newCategoryCount = viewModel.categoryImportPlan.primaryCategoriesToCreate.count
                    + viewModel.categoryImportPlan.subCategoriesToCreate.count
                if newCategoryCount > 0 {
                    infoRow(label: "将新建科目", value: "\(newCategoryCount) 个")
                }
                if !viewModel.parseFailures.isEmpty {
                    infoRow(label: "跳过", value: "\(viewModel.parseFailures.count) 条（格式异常）")
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

    private var mappingSection: some View {
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
                mappingRow("日期", index: viewModel.fieldMapping.dateIndex)
                mappingRow("类型", index: viewModel.fieldMapping.typeIndex)
                mappingRow("金额", index: viewModel.fieldMapping.amountIndex)
                mappingRow("一级分类", index: viewModel.fieldMapping.primaryCategoryIndex)
                mappingRow("二级分类", index: viewModel.fieldMapping.subCategoryIndex)
                mappingRow("账户", index: viewModel.fieldMapping.accountIndex)
                mappingRow("备注", index: viewModel.fieldMapping.noteIndex)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    /// 映射行：HOLO 字段 → CSV 列名
    private func mappingRow(_ holoField: String, index: Int?) -> some View {
        HStack {
            Text(holoField)
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 60, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 10))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            if let idx = index, idx < viewModel.previewData.headers.count {
                Text(viewModel.previewData.headers[idx])
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

                        if warning.isBlocking {
                            Button {
                                warning.isConfirmed = true
                                viewModel.confirmFallbackDate(rowIndex: warning.rowIndex)
                            } label: {
                                Text("确认使用今天日期")
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

            // 去重后的匹配列表（最多显示 10 条，可点击编辑）
            if !viewModel.uniqueMatchResults.isEmpty {
                VStack(spacing: 6) {
                    ForEach(viewModel.sortedUniqueMatchResults.prefix(10)) { result in
                        categoryMatchRow(result)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.editingMatchKey = MatchKeyWrapper(result.uniqueKey)
                            }
                    }

                    if viewModel.sortedUniqueMatchResults.count > 10 {
                        Text("...还有 \(viewModel.sortedUniqueMatchResults.count - 10) 个分类")
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary)
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

    /// 分类匹配行（可点击）
    private func categoryMatchRow(_ result: CategoryMatchResult) -> some View {
        HStack(spacing: 8) {
            // 原始分类名
            Text(result.originalSub)
                .font(.system(size: 13))
                .foregroundColor(.holoTextPrimary)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)

            // 箭头
            Image(systemName: "arrow.right")
                .font(.system(size: 10))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            // 匹配结果
            if let matched = result.matchedCategory {
                HStack(spacing: 4) {
                    categoryIconGlyph(
                        categoryIconName(for: matched),
                        size: 14,
                        color: matchTypeColor(result.matchType)
                    )
                    Text(matched.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(matchTypeColor(result.matchType))
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                    Text("新建科目")
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }
            }

            Spacer()

            // 可手动调整
            if result.willCreateOriginalCategory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.holoTextSecondary.opacity(0.5))
            }

            // 匹配类型标签
            Text(matchTypeLabel(result.matchType))
                .font(.system(size: 10))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(matchTypeColor(result.matchType))
                .clipShape(Capsule())
        }
    }

    /// 获取分类图标名称
    private func categoryIconName(for category: Category) -> String {
        category.icon
    }

    /// 匹配类型标签
    private func matchTypeLabel(_ type: CategoryMatchType) -> String {
        switch type {
        case .exact: return "精确"
        case .synonym: return "同义词"
        case .fuzzy: return "相似"
        case .unmatched: return "新建"
        }
    }

    /// 匹配类型颜色
    private func matchTypeColor(_ type: CategoryMatchType) -> Color {
        switch type {
        case .exact: return .green
        case .synonym: return .blue
        case .fuzzy: return .orange
        case .unmatched: return .red
        }
    }

    // MARK: - 数据预览

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "eye")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoPrimary)
                Text("数据预览（前 5 条）")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }

            // 横向可滚动的数据表
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    // 表头行
                    HStack(spacing: 0) {
                        ForEach(viewModel.previewData.headers.indices, id: \.self) { i in
                            Text(viewModel.previewData.headers[i])
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
                    ForEach(Array(viewModel.previewData.rows.prefix(5).enumerated()), id: \.offset) { _, row in
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
                Text("\(viewModel.parseFailures.count) 条记录将被跳过")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.orange)
            }

            // 最多展示前 5 条错误
            ForEach(Array(viewModel.parseFailures.prefix(5).enumerated()), id: \.offset) { _, failure in
                Text("第 \(failure.index) 行：\(failure.error)")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
            }

            if viewModel.parseFailures.count > 5 {
                Text("...还有 \(viewModel.parseFailures.count - 5) 条")
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

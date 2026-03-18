//
//  ImportPreviewSheet.swift
//  Holo
//
//  导入预览弹窗 — 显示解析结果、字段映射、数据预览
//  用户确认后执行批量导入
//

import SwiftUI

// MARK: - ImportPreviewSheet

/// 导入预览弹窗
struct ImportPreviewSheet: View {
    
    @Environment(\.dismiss) var dismiss
    
    /// 解析后的预览数据
    let previewData: ImportPreviewData
    /// 导入完成回调
    let onComplete: (BatchImportResult) -> Void
    
    /// 导入进度
    @State private var progress: ImportProgress = .idle
    /// 解析错误条目
    @State private var parseFailures: [(index: Int, error: String)] = []
    /// 成功解析条目数
    @State private var parsedItemCount: Int = 0
    /// 分类匹配结果（每条交易对应一个匹配结果）
    @State private var categoryMatchResults: [CategoryMatchResult] = []
    /// 去重后的分类匹配结果（用于预览）
    @State private var uniqueMatchResults: [CategoryMatchResult] = []
    /// 匹配统计
    @State private var matchStats: (exact: Int, synonym: Int, fuzzy: Int, unmatched: Int) = (0, 0, 0, 0)
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部信息栏
                headerSection
                
                Divider()
                
                ScrollView {
                    VStack(spacing: HoloSpacing.lg) {
                        // 检测结果卡片
                        detectionCard

                        // 字段映射展示
                        mappingSection

                        // 分类匹配预览
                        categoryMatchSection

                        // 数据预览（前 5 行）
                        previewSection

                        // 解析警告
                        if !parseFailures.isEmpty {
                            warningSection
                        }
                    }
                    .padding(HoloSpacing.lg)
                }
                
                // 底部按钮
                bottomActions
            }
            .background(Color.holoBackground)
            .navigationBarHidden(true)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { performPreParse() }
        .swipeBackToDismiss { dismiss() }
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
                infoRow(label: "文件名", value: previewData.fileName)
                infoRow(label: "识别格式", value: previewData.detectedTemplate.rawValue)
                infoRow(label: "总行数", value: "\(previewData.rows.count) 条记录")
                infoRow(label: "可导入", value: "\(parsedItemCount) 条")
                if !parseFailures.isEmpty {
                    infoRow(label: "跳过", value: "\(parseFailures.count) 条（格式异常）")
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
            }
            
            VStack(spacing: 6) {
                mappingRow("日期", index: previewData.fieldMapping.dateIndex)
                mappingRow("类型", index: previewData.fieldMapping.typeIndex)
                mappingRow("金额", index: previewData.fieldMapping.amountIndex)
                mappingRow("一级分类", index: previewData.fieldMapping.primaryCategoryIndex)
                mappingRow("二级分类", index: previewData.fieldMapping.subCategoryIndex)
                mappingRow("账户", index: previewData.fieldMapping.accountIndex)
                mappingRow("备注", index: previewData.fieldMapping.noteIndex)
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
            
            if let idx = index, idx < previewData.headers.count {
                Text(previewData.headers[idx])
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

    // MARK: - 分类匹配预览

    private var categoryMatchSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 标题
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "link")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoPrimary)
                Text("分类匹配预览")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }

            // 匹配统计
            HStack(spacing: HoloSpacing.md) {
                matchStatBadge(label: "精确", count: matchStats.exact, color: .green)
                matchStatBadge(label: "同义词", count: matchStats.synonym, color: .blue)
                matchStatBadge(label: "相似", count: matchStats.fuzzy, color: .orange)
                matchStatBadge(label: "待确认", count: matchStats.unmatched, color: .red)
            }

            // 去重后的匹配列表（最多显示 10 条）
            if !uniqueMatchResults.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(uniqueMatchResults.prefix(10).enumerated()), id: \.element.uniqueKey) { _, result in
                        categoryMatchRow(result)
                    }

                    if uniqueMatchResults.count > 10 {
                        Text("...还有 \(uniqueMatchResults.count - 10) 个分类")
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

    /// 分类匹配行
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
                    Image(categoryIconName(for: matched))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(matched.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(matchTypeColor(result.matchType))
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                    Text("新建分类")
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }
            }

            Spacer()

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
        case .unmatched: return "待确认"
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
                        ForEach(previewData.headers.indices, id: \.self) { i in
                            Text(previewData.headers[i])
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
                    ForEach(Array(previewData.rows.prefix(5).enumerated()), id: \.offset) { _, row in
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
                Text("\(parseFailures.count) 条记录将被跳过")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.orange)
            }
            
            // 最多展示前 5 条错误
            ForEach(Array(parseFailures.prefix(5).enumerated()), id: \.offset) { _, failure in
                Text("第 \(failure.index) 行：\(failure.error)")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
            }
            
            if parseFailures.count > 5 {
                Text("...还有 \(parseFailures.count - 5) 条")
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
                Button { performImport() } label: {
                    HStack {
                        if case .importing = progress {
                            ProgressView()
                                .tint(.white)
                                .padding(.trailing, 4)
                        }
                        Text(importButtonText)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(parsedItemCount > 0 ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                }
                .disabled(parsedItemCount == 0 || isImporting)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoCardBackground)
    }
    
    private var importButtonText: String {
        if case .importing(let current, let total) = progress {
            return "导入中 \(current)/\(total)"
        }
        return "导入 \(parsedItemCount) 条"
    }
    
    private var isImporting: Bool {
        if case .importing = progress { return true }
        return false
    }
    
    // MARK: - 逻辑方法

    /// 预解析：在显示预览时先转换数据，统计成功/失败条数，执行分类匹配
    private func performPreParse() {
        let (items, failures) = DataImportService.shared.convertToImportItems(
            data: previewData,
            mapping: previewData.fieldMapping
        )
        parsedItemCount = items.count
        parseFailures = failures

        // 执行分类智能匹配
        Task { @MainActor in
            await performCategoryMatching(items: items)
        }
    }

    /// 执行分类智能匹配
    @MainActor
    private func performCategoryMatching(items: [ImportTransactionItem]) async {
        // 获取所有分类
        guard let categories = try? await FinanceRepository.shared.getAllCategories() else {
            return
        }

        // 批量匹配
        categoryMatchResults = CategoryMatcherService.shared.batchMatchCategories(
            items: items,
            categories: categories
        )

        // 生成统计
        matchStats = CategoryMatcherService.shared.generateMatchStatistics(results: categoryMatchResults)

        // 去重用于预览显示
        uniqueMatchResults = CategoryMatcherService.shared.deduplicateResults(categoryMatchResults)
    }

    /// 执行导入
    private func performImport() {
        let (items, _) = DataImportService.shared.convertToImportItems(
            data: previewData,
            mapping: previewData.fieldMapping
        )

        guard !items.isEmpty else { return }

        progress = .importing(current: 0, total: items.count)

        Task {
            // 使用匹配结果进行导入
            let result = await FinanceRepository.shared.batchImportTransactionsWithMatchResults(
                items,
                matchResults: categoryMatchResults
            ) { current, total in
                Task { @MainActor in
                    progress = .importing(current: current, total: total)
                }
            }

            progress = .completed(result)
            dismiss()
            onComplete(result)
        }
    }
}

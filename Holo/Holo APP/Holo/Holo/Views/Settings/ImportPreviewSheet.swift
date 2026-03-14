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
        .background(Color.white)
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
        .background(Color.white)
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
        .background(Color.white)
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
                        .background(Color.white)
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
        .background(Color.white)
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
    
    /// 预解析：在显示预览时先转换数据，统计成功/失败条数
    private func performPreParse() {
        let (items, failures) = DataImportService.shared.convertToImportItems(
            data: previewData,
            mapping: previewData.fieldMapping
        )
        parsedItemCount = items.count
        parseFailures = failures
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
            let result = await FinanceRepository.shared.batchImportTransactions(items) { current, total in
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

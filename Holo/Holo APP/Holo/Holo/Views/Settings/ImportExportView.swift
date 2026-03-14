//
//  ImportExportView.swift
//  Holo
//
//  数据导入导出主视图 — 嵌入在 FinanceSettingsView 中
//  提供导出数据、导入数据、下载模板三个入口
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - ImportExportView

/// 导入导出功能入口视图（设置页内嵌）
struct ImportExportView: View {
    
    /// 是否显示导出选项 Sheet
    @State private var showExportSheet = false
    /// 是否显示文件选择器（导入）
    @State private var showFilePicker = false
    /// 是否显示导入预览 Sheet
    @State private var showImportPreview = false
    /// 导入解析后的预览数据
    @State private var importPreviewData: ImportPreviewData? = nil
    /// 操作进行中提示
    @State private var isExporting = false
    /// 分享文件 URL
    @State private var shareFileURL: URL? = nil
    /// 错误提示
    @State private var errorMessage: String? = nil
    /// 是否显示错误弹窗
    @State private var showError = false
    /// 导入成功结果
    @State private var importResult: BatchImportResult? = nil
    /// 是否显示导入结果弹窗
    @State private var showImportResult = false
    
    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            // 区块标题
            HStack {
                Text("数据管理")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
            }
            
            // 导出数据
            settingsRow(
                icon: "square.and.arrow.up",
                iconColor: .holoPrimary,
                title: "导出数据",
                subtitle: "导出交易记录为 CSV 或 JSON"
            ) {
                showExportSheet = true
            }
            
            // 导入数据
            settingsRow(
                icon: "square.and.arrow.down",
                iconColor: .holoSuccess,
                title: "导入数据",
                subtitle: "从 CSV 文件导入交易记录"
            ) {
                showFilePicker = true
            }
            
            // 下载导入模板
            settingsRow(
                icon: "doc.text",
                iconColor: .holoTextSecondary,
                title: "下载导入模板",
                subtitle: "获取标准 CSV 模板文件"
            ) {
                downloadTemplate()
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        // 导出选项 Sheet
        .sheet(isPresented: $showExportSheet) {
            ExportOptionsSheet()
        }
        // 文件选择器（导入）
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        // 导入预览 Sheet
        .sheet(isPresented: $showImportPreview) {
            if let data = importPreviewData {
                ImportPreviewSheet(previewData: data) { batchResult in
                    importResult = batchResult
                    showImportResult = true
                }
            }
        }
        // 分享 Sheet
        .sheet(isPresented: Binding(
            get: { shareFileURL != nil },
            set: { if !$0 { shareFileURL = nil } }
        )) {
            if let url = shareFileURL {
                ShareSheet(items: [url])
            }
        }
        // 错误提示
        .alert("操作失败", isPresented: $showError) {
            Button("确定") {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        // 导入结果提示
        .alert("导入完成", isPresented: $showImportResult) {
            Button("确定") {
                NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
            }
        } message: {
            if let result = importResult {
                Text("成功导入 \(result.successCount) 条交易\(result.failedItems.isEmpty ? "" : "，\(result.failedItems.count) 条失败")\(result.newCategoriesCount > 0 ? "\n新建 \(result.newCategoriesCount) 个分类" : "")\(result.newAccountsCount > 0 ? "\n新建 \(result.newAccountsCount) 个账户" : "")")
            }
        }
    }
    
    // MARK: - 设置行组件
    
    /// 通用设置行样式
    private func settingsRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.md) {
                // 图标
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconColor.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(iconColor)
                }
                
                // 文字
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary.opacity(0.5))
            }
            .padding(HoloSpacing.md)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - 操作方法
    
    /// 下载导入模板
    private func downloadTemplate() {
        let url = DataExportService.shared.generateImportTemplate()
        shareFileURL = url
    }
    
    /// 处理文件选择结果
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // 开始安全访问
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "无法访问所选文件"
                showError = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            
            do {
                let previewData = try DataImportService.shared.parseCSV(url: url)
                importPreviewData = previewData
                showImportPreview = true
            } catch {
                errorMessage = "文件解析失败：\(error.localizedDescription)"
                showError = true
            }
            
        case .failure(let error):
            errorMessage = "选择文件失败：\(error.localizedDescription)"
            showError = true
        }
    }
}

// MARK: - 导出选项 Sheet

/// 导出选项弹窗 — 选择格式和日期范围
struct ExportOptionsSheet: View {
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedFormat: ExportFormat = .csv
    @State private var selectedRange: ExportDateRange = .all
    @State private var isExporting = false
    @State private var shareURL: URL? = nil
    @State private var errorMessage: String? = nil
    @State private var showError = false
    
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
                    // 格式选择
                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        Text("导出格式")
                            .font(.holoHeading)
                            .foregroundColor(.holoTextPrimary)
                        
                        ForEach(ExportFormat.allCases) { format in
                            formatOption(format)
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    
                    // 日期范围
                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        Text("日期范围")
                            .font(.holoHeading)
                            .foregroundColor(.holoTextPrimary)
                        
                        // 使用 FlowLayout 式的标签
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 8) {
                            ForEach(ExportDateRange.allCases.filter { $0 != .custom }) { range in
                                rangeTag(range)
                            }
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    
                    Spacer()
                    
                    // 导出按钮
                    Button {
                        performExport()
                    } label: {
                        HStack {
                            if isExporting {
                                ProgressView()
                                    .tint(.white)
                                    .padding(.trailing, 4)
                            }
                            Text(isExporting ? "导出中..." : "导出")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.holoPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                    }
                    .disabled(isExporting)
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.bottom, HoloSpacing.lg)
                }
            }
            .background(Color.holoBackground)
            .navigationBarHidden(true)
        }
        .presentationDetents([.height(460)])
        .presentationDragIndicator(.hidden)
        // 分享
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .alert("导出失败", isPresented: $showError) {
            Button("确定") {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }
    
    /// 格式选项卡
    private func formatOption(_ format: ExportFormat) -> some View {
        Button {
            selectedFormat = format
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(format.rawValue)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text(format.description)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer()
                Image(systemName: selectedFormat == format ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selectedFormat == format ? .holoPrimary : .holoTextSecondary.opacity(0.3))
                    .font(.system(size: 20))
            }
            .padding(HoloSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .stroke(selectedFormat == format ? Color.holoPrimary.opacity(0.3) : Color.clear, lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    /// 日期范围标签
    private func rangeTag(_ range: ExportDateRange) -> some View {
        Button {
            selectedRange = range
        } label: {
            Text(range.rawValue)
                .font(.system(size: 14, weight: selectedRange == range ? .semibold : .medium))
                .foregroundColor(selectedRange == range ? .holoPrimary : .holoTextSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(selectedRange == range ? Color.holoPrimary.opacity(0.1) : Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(selectedRange == range ? Color.holoPrimary.opacity(0.3) : Color.holoDivider, lineWidth: 1)
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    /// 执行导出
    private func performExport() {
        isExporting = true
        Task {
            do {
                let url = try await DataExportService.shared.generateExportFile(
                    format: selectedFormat,
                    dateRange: selectedRange.dateRange
                )
                shareURL = url
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isExporting = false
        }
    }
}

// MARK: - ShareSheet（UIKit 桥接）

/// UIActivityViewController 的 SwiftUI 包装
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

//
//  BillExcelReader.swift
//  Holo
//
//  银行账单 xlsx 读取（CoreXLSX）
//  方案：docs/plans/2026-08-17-finance-bill-import-ai-plan.md §3 Excel 支持边界
//
//  设计：xlsx 读成行矩阵后转写成严格转义的临时 CSV，之后完全复用现有
//  扫描/预览/流式导入管线——一条管线保证账单在两种文件形态下行为一致。
//
//  日期处理：Excel 的日期本质是「带日期样式的数字序列号」，CoreXLSX 的
//  cell.dateValue 依据样式还原为 Date；这里统一格式化为 "yyyy-MM-dd HH:mm"
//  再写 CSV，交由现有 parseDate 解析。金额一律保持原始字符串，不过数值化。
//

import Foundation
import CoreXLSX

enum BillExcelReader {

    enum ReadError: LocalizedError {
        case cannotOpen
        case emptySheet

        var errorDescription: String? {
            switch self {
            case .cannotOpen:
                return "无法读取该 Excel 文件（可能是不支持的 xls 老格式，请用 Excel 另存为 .xlsx 后重试）"
            case .emptySheet:
                return "Excel 文件里没有数据行"
            }
        }
    }

    /// 行数保护上限：超出则拒绝（xlsx 是全量载入，超预期的大文件先拦下来）
    private static let maxRows = 100_000

    /// 把 xlsx 转写成临时 CSV 文件，返回其 URL
    static func convertToCSV(url: URL) throws -> URL {
        let rows = try readRows(url: url)

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bill_excel_\(UUID().uuidString).csv")

        var csvText = ""
        for row in rows {
            csvText += row.map(escapeCSVField).joined(separator: ",")
            csvText += "\n"
        }
        try csvText.write(to: destinationURL, atomically: true, encoding: .utf8)
        return destinationURL
    }

    /// 读取 xlsx 为字符串行矩阵
    /// - Returns: 每行每列的字符串值；自动选取行数最多的 sheet 作为数据表
    static func readRows(url: URL) throws -> [[String]] {
        guard let file = try? XLSXFile(filepath: url.path) else {
            throw ReadError.cannotOpen
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let sharedStrings = try? file.parseSharedStrings()

        // 多 sheet 的银行账单：首页常是说明页，取行数最多的作为数据表
        var bestRows: [[String]] = []
        let paths = try file.parseWorksheetPaths()
        for path in paths {
            guard let worksheet = try? file.parseWorksheet(at: path) else { continue }
            var rows: [[String]] = []
            for row in worksheet.sheetData.rows {
                var cells: [String] = []
                var lastColumn = 0
                for cell in row.cells {
                    // 空 cell 补位（列号连续性）
                    let column = columnIndex(cell.reference.description)
                    while lastColumn < column - 1 {
                        cells.append("")
                        lastColumn += 1
                    }
                    cells.append(cellValueText(cell, sharedStrings: sharedStrings, dateFormatter: dateFormatter))
                    lastColumn = column
                }
                rows.append(cells)
            }
            if rows.count > bestRows.count {
                bestRows = rows
            }
        }

        guard !bestRows.isEmpty else { throw ReadError.emptySheet }
        guard bestRows.count <= maxRows else {
            throw ReadError.cannotOpen
        }
        return bestRows
    }

    // MARK: - Cell 值转文本

    private static func cellValueText(_ cell: Cell, sharedStrings: SharedStrings?, dateFormatter: DateFormatter) -> String {
        // 日期样式优先（银行账单的交易日期列）
        if let date = cell.dateValue {
            return dateFormatter.string(from: date)
        }
        if let sharedStrings, let text = cell.stringValue(sharedStrings) {
            return text
        }
        // 纯数字（金额列）：保留原始文本表示，交给 cleanAmount 处理
        if let raw = cell.value, !raw.isEmpty {
            return raw
        }
        return ""
    }

    /// 列引用（如 "B3"）→ 列序号（A=1, B=2 ...）
    private static func columnIndex(_ reference: String) -> Int {
        var sum = 0
        for scalar in reference.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { break }
            sum = sum * 26 + Int(scalar.value - 64)
        }
        return sum
    }

    /// 严格 CSV 转义：含引号/逗号/换行的字段用引号包裹，内部引号翻倍
    private static func escapeCSVField(_ field: String) -> String {
        if field.contains("\"") || field.contains(",") || field.contains("\n") || field.contains("\r") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }
}

//
//  BillArchiveExtractor.swift
//  Holo
//
//  账单压缩包解压（微信/支付宝邮箱导出的 zip）
//  方案：docs/plans/2026-08-17-finance-bill-import-ai-plan.md §4 步骤ⓢ / §12 二期
//
//  现实约束（2026-08-17 实测）：ZIPFoundation 0.9.20 已移除密码解压支持
//  （官方因 ZipCrypto 安全性移除，且从未支持 AES）。因此一期策略：
//  - 无加密 zip：应用内直接解压 ✅
//  - 加密 zip（微信/支付宝邮箱导出的默认形态）：检测到加密标志后走教程引导
//    （降级路径，方案 A1 预设）；拿到真实样本评估后再决定是否引入专用解密库（二期）
//

import Foundation
import ZIPFoundation

enum BillArchiveExtractor {

    enum ExtractError: LocalizedError {
        case notArchive
        case noBillFileInside
        case passwordProtected

        var errorDescription: String? {
            switch self {
            case .notArchive:
                return "这不是有效的压缩包文件"
            case .noBillFileInside:
                return "压缩包内没有找到账单文件（csv/txt/xlsx）"
            case .passwordProtected:
                return "无法在 App 内解压该压缩包。\n微信/支付宝导出的账单是加密压缩包（解压密码在对应 App 里显示），请先在电脑上解压，再把解压出来的 CSV/XLSX 文件导入。"
            }
        }
    }

    /// 解压账单 zip，返回其中的数据文件（csv/txt/tsv/xlsx）落盘后的 URL
    static func extract(archiveURL: URL) throws -> URL {
        guard let archive = Archive(url: archiveURL, accessMode: .read) else {
            throw ExtractError.notArchive
        }

        // 找到第一个账单数据文件（跳过 macOS 目录垃圾与隐藏文件）
        let supportedExtensions: Set<String> = ["csv", "txt", "tsv", "xlsx"]
        var targetEntry: Entry?
        for entry in archive {
            let path = entry.path.lowercased()
            guard !path.hasPrefix("__macosx"), !path.contains("/._") else { continue }
            let ext = (path as NSString).pathExtension
            if supportedExtensions.contains(ext) {
                targetEntry = entry
                break
            }
        }
        guard let entry = targetEntry else {
            throw ExtractError.noBillFileInside
        }

        let ext = (entry.path.lowercased() as NSString).pathExtension
        let destinationDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bill_extract_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let destinationURL = destinationDir.appendingPathComponent("bill.\(ext)")

        do {
            _ = try archive.extract(entry, to: destinationURL)
        } catch {
            // 加密 zip（微信/支付宝邮箱导出）提取必失败：ZIPFoundation 已移除密码 API。
            // 一期按方案 A1 降级路径处理——教程引导用户先在电脑上解压。
            throw ExtractError.passwordProtected
        }
        return destinationURL
    }
}

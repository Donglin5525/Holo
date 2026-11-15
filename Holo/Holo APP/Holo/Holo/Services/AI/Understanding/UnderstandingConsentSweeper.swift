//
//  UnderstandingConsentSweeper.swift
//  Holo
//
//  理解引擎 P1 挂账速修（2026-11-15）：AI 数据处理授权撤销 → 影子残留全清。
//
//  数据边界（工程稿 §5.2）：影子产物（索引/主题快照/台账/评审包）只在授权内
//  存在——用户关闭授权后本机不留影子痕迹。授权门拦「新跑」（DataSource 空输入），
//  本件拦「存量残留」。
//

import Foundation

@MainActor
enum UnderstandingConsentSweeper {

    /// App 启动安装（HoloApp 传 .holoAIDataProcessingConsentDidChange）。
    /// 通知名参数化：本文件保持纯 Foundation（standalone 可测），App 侧符号不进编译面。
    /// 常驻监听：授权撤销通知 → 清除。
    static func install(_ consentChangeNotification: Notification.Name) {
        NotificationCenter.default.addObserver(
            forName: consentChangeNotification,
            object: nil,
            queue: .main
        ) { note in
            guard note.userInfo?["granted"] as? Bool == false else { return }
            MainActor.assumeIsolated {
                clearShadowArtifacts()
            }
        }
    }

    /// 清除全部影子产物：Application Support 影子目录（索引/主题/台账）+
    /// Documents 评审包 JSON。目录与文件均可重建，直接整删。
    static func clearShadowArtifacts(storage: URL? = nil, documents: URL? = nil) {
        let storageDir = storage ?? UnderstandingShadowRunner.storageDirectory()
        try? FileManager.default.removeItem(at: storageDir)
        let docs = documents
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("UnderstandingShadowReport-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

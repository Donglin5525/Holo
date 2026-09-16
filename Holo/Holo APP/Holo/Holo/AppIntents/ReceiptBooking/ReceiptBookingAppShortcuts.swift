//
//  ReceiptBookingAppShortcuts.swift
//  Holo
//
//  图片快捷指令自动记账 · 系统发现（2026-09-14 完整方案 §10.1/§22.4）
//  AppShortcutsProvider 让 Holo 动作与 Siri 口令出现在系统里；
//  组合快捷指令（截屏 → Holo 动作）仍需用户在快捷指令 App 里安装官方模板（§22.4）。
//

import AppIntents

struct ReceiptBookingAppShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecognizeAndBookReceiptIntent(),
            phrases: [
                "用 \(.applicationName) 识别账单",
                "用 \(.applicationName) 记这张图",
                "用 \(.applicationName) 记账",
            ],
            shortTitle: "识别图片并记账",
            systemImageName: "photo.badge.checkmark"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .blue
    }
}

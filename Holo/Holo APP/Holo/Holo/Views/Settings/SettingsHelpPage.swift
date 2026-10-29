//
//  SettingsHelpPage.swift
//  Holo
//
//  使用帮助直接从设置进入；重看动作由宿主负责退回首页。
//

import SwiftUI

struct SettingsHelpPage: View {
    let onReplayCoachTour: () -> Void
    let onReplayWelcomeNote: () -> Void

    var body: some View {
        SettingsSheetShell(String(localized: "使用帮助")) {
            VStack(spacing: 0) {
                SettingsNavRow(icon: "hand.point.up.left", iconColor: .holoInfo,
                               title: "重看新手引导", subtitle: "认识首页入口与基本操作", action: onReplayCoachTour)
                SettingsRowDivider()
                SettingsNavRow(icon: "note.text", iconColor: .holoInfo,
                               title: "重看新人笔记", subtitle: "查看 Holo 的使用说明", action: onReplayWelcomeNote)
            }
            .holoSurface()
        }
    }
}

/// 复用财务模块的真实导入导出流程，明确只处理账单，不宣称全 App 备份。
struct SettingsFinanceTransferPage: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    Text("这里导入或导出财务账单，其他模块的记录不包含在内。")
                        .holoText(.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .padding(.horizontal, HoloSpacing.lg)
                    ImportExportView()
                }
                .padding(.vertical, HoloSpacing.md)
                .holoContentColumn(paintsBackground: false)
            }
            .background(Color.holoToolBackground)
            .navigationTitle("账单导入与导出")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.navLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

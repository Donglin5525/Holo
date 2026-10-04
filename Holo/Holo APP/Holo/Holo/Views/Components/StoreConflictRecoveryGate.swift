//
//  StoreConflictRecoveryGate.swift
//  Holo
//
//  存储冲突恢复的用户可见状态（D03，2026-10-04 体检）。
//
//  CoreDataStack 遇到模型指纹冲突会自动「备份旧库 + 重建空库」（防启动闪退），
//  此前这一过程对用户完全静默——升级后看到空 App 等于「记录全丢了」的信任事故。
//  本门在启动时检查恢复标记：发现未确认的恢复事件即如实说明发生了什么、
//  旧数据在哪，并提供备份文件导出；用户确认后清除标记不再打扰。
//

import SwiftUI

struct StoreConflictRecoveryGate: ViewModifier {

    @State private var pendingEvent: CoreDataStack.ConflictRecoveryEvent?
    @State private var showBackupShare = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                pendingEvent = CoreDataStack.pendingConflictRecoveryEvent()
            }
            .alert(
                "数据已自动保护",
                isPresented: Binding(
                    get: { pendingEvent != nil },
                    set: { if !$0 { acknowledge() } }
                )
            ) {
                Button("导出旧数据备份") {
                    showBackupShare = true
                }
                Button("知道了", role: .cancel) {
                    acknowledge()
                }
            } message: {
                Text("检测到本地数据文件与当前版本不兼容，Holo 已自动备份原有数据并新建了空库。开启 iCloud 同步时云端数据会逐步恢复；备份文件仍保留在设备上，可随时导出留底。")
            }
            .sheet(isPresented: $showBackupShare, onDismiss: { acknowledge() }) {
                if let backupURLs = pendingEvent?.backupFileURLs, !backupURLs.isEmpty {
                    ShareSheet(items: backupURLs)
                }
            }
    }

    /// 用户看过说明/处理过导出即确认；标记清除后不再打扰（备份文件本体保留）
    private func acknowledge() {
        CoreDataStack.acknowledgeConflictRecovery()
        pendingEvent = nil
    }
}

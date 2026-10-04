//
//  StoreConflictRecoveryGate.swift
//  Holo
//
//  存储冲突恢复的用户可见状态（D03，2026-10-04 体检；R01/R02/R16 同批收口）。
//
//  CoreDataStack 遇到模型指纹冲突会自动「完整备份旧库 + 重建空库」（防启动闪退，
//  备份不完整时不重建），此前这一过程对用户完全静默——升级后看到空 App 等于
//  「记录全丢了」的信任事故。本门在存储加载到达终态后检查恢复标记：发现未确认的
//  恢复事件即如实说明发生了什么、旧数据在哪，并提供备份文件导出；加载彻底失败时
//  如实说明并保留原库等待救援。用户确认后清除标记不再打扰。
//

import SwiftUI

struct StoreConflictRecoveryGate: ViewModifier {

    @State private var pendingEvent: CoreDataStack.ConflictRecoveryEvent?
    @State private var storageFailureDetail: String?
    @State private var showBackupShare = false
    /// R16：分享载荷快照——确认弹层关闭会清掉 pendingEvent，sheet 若直接依赖它，
    /// 点「导出」的瞬间就会拿到空列表（弹层关闭先于 sheet 呈现）。
    @State private var sharePayload: [URL] = []

    func body(content: Content) -> some View {
        content
            .task {
                // R16（2026-10-04 体检）：恢复标记在加载完成回调内写入，而 root 视图
                // 的出现远早于异步加载完成——旧实现只在 onAppear 读一次必然错过
                // 本次启动的恢复事件。等待加载终态后再查，时间线上保证不漏。
                await CoreDataStack.shared.waitUntilReady()
                pendingEvent = CoreDataStack.pendingConflictRecoveryEvent()
                if let error = CoreDataStack.shared.storeLoadError() {
                    storageFailureDetail = error.localizedDescription
                }
            }
            .alert(
                "数据已自动保护",
                isPresented: Binding(
                    get: { pendingEvent != nil },
                    set: { if !$0 { closeExplanation() } }
                )
            ) {
                Button("导出旧数据备份") {
                    // R16：先快照备份清单再关弹层开分享；只有走分享路径才不清 pendingEvent，
                    // 分享结束（含取消）在 onDismiss 统一确认
                    sharePayload = pendingEvent?.backupFileURLs ?? []
                    showBackupShare = true
                }
                Button("知道了", role: .cancel) {
                    acknowledge()
                }
            } message: {
                Text("检测到本地数据文件与当前版本不兼容，Holo 已自动备份原有数据并新建了空库。开启 iCloud 同步时云端数据会逐步恢复；备份文件仍保留在设备上，可随时导出留底。")
            }
            .alert(
                "存储暂时打不开",
                isPresented: Binding(
                    get: { storageFailureDetail != nil },
                    set: { if !$0 { storageFailureDetail = nil } }
                )
            ) {
                Button("知道了", role: .cancel) {}
            } message: {
                // R01：加载失败不再闪退，也不假装正常——如实说明并保留原库；
                // 不承诺自动修复，重启重试与联系支持是用户仅有的可靠动作
                Text("本地数据库无法打开，你的原始数据仍保留在设备上，没有被删除。请尝试重启手机后再打开 Holo；若仍然失败，请通过「我的 → 设置」联系支持。")
            }
            .sheet(isPresented: $showBackupShare, onDismiss: { acknowledge() }) {
                if !sharePayload.isEmpty {
                    ShareSheet(items: sharePayload)
                }
            }
    }

    /// 关闭说明弹层：分享路径尚未结束，先不清确认标记（R16：
    /// 「已知晓说明」与「导出完成/取消」分别表达，分享中途被打断下次仍会提醒）
    private func closeExplanation() {
        if sharePayload.isEmpty {
            acknowledge()
        }
    }

    /// 用户看过说明/处理过导出即确认；标记清除后不再打扰（备份文件本体保留）
    private func acknowledge() {
        CoreDataStack.acknowledgeConflictRecovery()
        pendingEvent = nil
        sharePayload = []
    }
}

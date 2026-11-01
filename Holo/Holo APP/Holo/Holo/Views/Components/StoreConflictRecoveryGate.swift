//
//  StoreConflictRecoveryGate.swift
//  Holo
//
//  存储冲突恢复的用户可见状态（D03，2026-10-04 体检；R01/R02/R16 同批收口）。
//
//  库加载成功前不挂载业务页面及其生命周期任务，失败时展示可交互的说明页。
//  未知模型差异不再自动重建空库。仍识别旧版本留下的恢复标记并提供备份导出，
//  避免已有的保护事件和备份记录被这次升级隐藏。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct StoreConflictRecoveryGate: ViewModifier {

    private enum LaunchPhase {
        case loading
        case ready
        case failed(String)
    }

    @State private var phase: LaunchPhase = .loading

    @State private var pendingEvent: CoreDataStack.ConflictRecoveryEvent?
    @State private var showBackupShare = false
    /// R16：分享载荷快照——确认弹层关闭会清掉 pendingEvent，sheet 若直接依赖它，
    /// 点「导出」的瞬间就会拿到空列表（弹层关闭先于 sheet 呈现）。
    @State private var sharePayload: [URL] = []

    func body(content: Content) -> some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("正在加载…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.holoBackground)
            case .ready:
                content
            case .failed(let detail):
                VStack(spacing: HoloSpacing.lg) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.largeTitle)
                    Text("存储暂时打不开")
                        .font(.headline)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Button("复制") {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = detail
                        #endif
                    }
                    .buttonStyle(.bordered)
                }
                .padding(HoloSpacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.holoBackground)
            }
        }
            .task {
                // waitUntilReady 的失败也是终态，必须先检查错误，不能直接放行业务读写。
                await CoreDataStack.shared.waitUntilReady()
                if let error = CoreDataStack.shared.storeLoadError() {
                    phase = .failed(error.localizedDescription)
                    return
                }
                guard CoreDataStack.shared.isReady else { return }
                pendingEvent = CoreDataStack.pendingConflictRecoveryEvent()
                phase = .ready
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

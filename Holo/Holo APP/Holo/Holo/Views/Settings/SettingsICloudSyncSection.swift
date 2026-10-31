//
//  SettingsICloudSyncSection.swift
//  Holo
//
//  设置页 iCloud 同步区块（2026-10-24 随「真机点设置必崩」栈溢出修复拆出）：
//  SettingsView 原巨型计算属性内联整棵子树，登录态分支下真机主线程栈溢出
//  （.ips 实锤 closure in SettingsView.iCloudSyncSection.getter 元数据递归爆栈）。
//  拆独立 struct 封顶单帧（ChatView 四次发作固化的「叶子拆出去、层级不增加」范式）。
//

import SwiftUI
import CloudKit

struct SettingsICloudSyncSection: View {

    /// 二级页场景（2026-10-25 规整收进门）传 false：导航栏标题顶替组头，不再重复
    var showsSectionHeader: Bool = true
    /// iCloud 使用系统账号，与 Holo 的 Apple 登录独立；默认展示真实同步状态。
    /// 保留参数以兼容既有宿主，旧页面可显式要求先展示 Holo 登录提示。
    var requiresHoloSignIn: Bool = false

    @ObservedObject private var iCloudSyncStatus = ICloudSyncStatusService.shared
    @ObservedObject private var authService = AppleSignInAuthService.shared

    @State private var iCloudRefreshToast: String?
    @State private var showSyncDiagnostics = false
    @State private var showCloudRepullConfirm = false
    @State private var showCloudRepull = false

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            if showsSectionHeader {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.holoPrimary)

                    Text("iCloud 同步")
                        .holoText(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoToolText)
                }
            }

            VStack(spacing: 0) {
                // 账号状态
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(Color.holoPrimary.opacity(0.1))
                            .frame(width: 40, height: 40)

                        Image(systemName: "person.icloud")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.holoPrimary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("账号状态")
                            .holoText(.body)
                            .foregroundColor(.holoToolText)

                        Text(iCloudAccountSubtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolTextSecondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 12)

                Divider()
                    .padding(.leading, 56)

                // 同步状态：上传/下载两个方向各自可见——
                // 「已上传本机数据」不再盖住「从未收到过云端数据」，开始（转圈）与结束（时间/失败）都看得见
                syncDirectionRow(
                    line: iCloudSyncStatus.exportStatusLine,
                    iconName: "icloud.and.arrow.up"
                )

                Divider()
                    .padding(.leading, 56)

                syncDirectionRow(
                    line: iCloudSyncStatus.importStatusLine,
                    iconName: "icloud.and.arrow.down"
                )

                // 同步自检指引：账号可用但从未收到过云端数据。
                // 分支一：连上传都没发生过 → 大概率是系统设置里 Holo 的 iCloud 权限被关；
                // 分支二：上传正常但从未收到 → 大概率是另一台设备没在上传（或两端连的
                // 不是同一个 iCloud 环境：一边开发版一边正式版）——旧版在这里只会显示
                // 「已上传本机数据」，把真正的问题完全盖住。
                if iCloudSyncStatus.isInitialSyncPending {
                    Divider()
                        .padding(.leading, 56)

                    HStack(spacing: HoloSpacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: HoloRadius.sm)
                                .fill(Color.holoInfo.opacity(0.1))
                                .frame(width: 40, height: 40)

                            Image(systemName: iCloudSyncStatus.neverReceivedFromCloud ? "icloud.and.arrow.down" : "icloud.slash")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.holoInfo)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(iCloudSyncStatus.neverReceivedFromCloud ? "还未收到云端数据" : "同步尚未开始")
                                .holoText(.body)
                                .foregroundColor(.holoToolText)

                            Text(
                                iCloudSyncStatus.neverReceivedFromCloud
                                    ? "本机数据已上传 iCloud，但从未收到过云端数据。如果你在其他设备也用 Holo，请检查那台设备的同步状态；正式版与开发版连的是两个不同的 iCloud 数据库，数据互不可见"
                                    : "请在 系统设置 → 顶部你的名字 → iCloud → 保存到 iCloud 中，确认 Holo 的开关已打开"
                            )
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, 12)
                }

                // iCloud 空间已满的专属指引：这是唯一「重试解决不了、必须用户动手清理」的错误，
                // 苹果没有公开 API 查剩余空间，只能在出错后如实告知出路
                if iCloudSyncStatus.lastErrorIsQuota, iCloudSyncStatus.lastErrorMessage != nil {
                    Divider()
                        .padding(.leading, 56)

                    HStack(spacing: HoloSpacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: HoloRadius.sm)
                                .fill(Color.orange.opacity(0.12))
                                .frame(width: 40, height: 40)

                            Image(systemName: "icloud.and.arrow.up")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.orange)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("如何恢复上传")
                                .holoText(.body)
                                .foregroundColor(.holoToolText)

                            Text("数据已安全保存在本机。请前往 系统设置 → 顶部你的名字 → iCloud → 管理账户存储 清理空间；清理完成后系统会自动恢复上传，无需手动操作。")
                                .font(.system(size: 12))
                                .foregroundColor(.holoToolTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, 12)
                }

                Divider()
                    .padding(.leading, 56)

                // 重新检查按钮
                Button {
                    guard !iCloudSyncStatus.isRefreshing else { return }
                    iCloudRefreshToast = nil
                    Task {
                        await iCloudSyncStatus.requestManualSync()
                        iCloudRefreshToast = iCloudSyncStatus.refreshToast
                        // 2 秒后隐藏 toast
                        try? await Task.sleep(for: .seconds(2))
                        iCloudRefreshToast = nil
                    }
                } label: {
                    HStack(spacing: HoloSpacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: HoloRadius.sm)
                                .fill(Color.holoInfo.opacity(0.1))
                                .frame(width: 40, height: 40)

                            if iCloudSyncStatus.isRefreshing {
                                ProgressView()
                                    .tint(.holoInfo)
                            } else {
                                Image(systemName: "arrow.clockwise.icloud")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.holoInfo)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(iCloudSyncStatus.isRefreshing ? String(localized: "正在同步…") : String(localized: "立即同步"))
                                .holoText(.body)
                                .foregroundColor(.holoInfo)

                            if let toast = iCloudRefreshToast {
                                Text(toast)
                                    .font(.system(size: 11))
                                    .foregroundColor(.holoSuccess)
                                    .transition(.opacity)
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                Divider()
                    .padding(.leading, 56)

                // 同步诊断：状态摘要 + 最近错误流水，用户报障排查用
                Button {
                    showSyncDiagnostics = true
                } label: {
                    HStack(spacing: HoloSpacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: HoloRadius.sm)
                                .fill(Color.holoPrimary.opacity(0.1))
                                .frame(width: 40, height: 40)

                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.holoPrimary)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("同步诊断")
                                .holoText(.body)
                                .foregroundColor(.holoToolText)

                            Text("查看同步状态与最近的错误记录")
                                .font(.system(size: 12))
                                .foregroundColor(.holoToolTextSecondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                // 从 iCloud 重新拉取（P2）：以云端为准重建本机库。有备份护栏，
                // 放在同步诊断之后——常规用户永远不需要点它，换机/数据可疑时它是救命入口。
                if CloudKitRuntimeAvailability.isAvailable {
                    Divider()
                        .padding(.leading, 56)

                    Button {
                        showCloudRepullConfirm = true
                    } label: {
                        HStack(spacing: HoloSpacing.md) {
                            ZStack {
                                RoundedRectangle(cornerRadius: HoloRadius.sm)
                                    .fill(Color.holoPrimary.opacity(0.1))
                                    .frame(width: 40, height: 40)

                                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.holoPrimary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("从 iCloud 重新拉取")
                                    .holoText(.body)
                                    .foregroundColor(.holoToolText)

                                Text("以云端数据为准覆盖本机（自动备份，可恢复）")
                                    .font(.system(size: 12))
                                    .foregroundColor(.holoToolTextSecondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                        }
                        .padding(.horizontal, HoloSpacing.md)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .alert("从 iCloud 重新拉取全部数据", isPresented: $showCloudRepullConfirm) {
                        Button("取消", role: .cancel) {}
                        Button("开始拉取", role: .destructive) {
                            showCloudRepull = true
                        }
                    } message: {
                        Text("本机当前数据将被删除，并用 iCloud 云端数据完整替换。开始前会自动备份本机数据，完成后可一键恢复。此过程需要保持网络连接，可能需要几分钟，期间不建议使用其他功能。")
                    }
                }
            }
            .background(Color.holoToolSurface)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .sheet(isPresented: $showSyncDiagnostics) {
                NavigationStack {
                    SyncDiagnosticsView()
                }
            }
            #if canImport(UIKit)
            .fullScreenCover(isPresented: $showCloudRepull) {
                CloudRepullView()
                    .task {
                        // 弹层即启动：确认弹层是唯一的入口闸，这里不再二次确认
                        await CloudRepullService.shared.start()
                    }
            }
            #else
                        .sheet(isPresented: $showCloudRepull) {
                CloudRepullView()
                    .task {
                        // 弹层即启动：确认弹层是唯一的入口闸，这里不再二次确认
                        await CloudRepullService.shared.start()
                    }
            }
            #endif
            // 手动同步的真实结果异步到达（探针上传事件落地或超时），转发到按钮下的提示位
            .onReceive(iCloudSyncStatus.$refreshToast) { toast in
                guard let toast else { return }
                iCloudRefreshToast = toast
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    iCloudRefreshToast = nil
                }
            }
        }
    }

    private var iCloudAccountSubtitle: String {
        // requiresHoloSignIn == false（Mac 宿主）时跳过登录门槛，直接落到
        // iCloud 账号状态如实呈现——Mac 版没有 Holo 账号登录体系
        if requiresHoloSignIn, !authService.isSignedIn {
            return String(localized: "登录 Holo 后检查云同步状态")
        }

        return SettingsSyncCopy.summary(for: iCloudSyncStatus)
    }

    /// iCloud 同步区块的上传/下载方向行：进行中转圈、成功带时间、失败带原因，
    /// 单方向四态互斥（数据来自 ICloudSyncStatusService 的 DirectionStatusLine）
    private func syncDirectionRow(line: ICloudSyncStatusService.DirectionStatusLine, iconName: String) -> some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .fill(line.hasError ? Color.holoError.opacity(0.1) : Color.holoPrimary.opacity(0.1))
                    .frame(width: 40, height: 40)

                if line.isInProgress {
                    ProgressView()
                        .tint(.blue)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(line.hasError ? .holoError : .holoPrimary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .holoText(.body)
                    .foregroundColor(.holoToolText)

                Text(line.detail)
                    .font(.system(size: 12))
                    .foregroundColor(line.hasError ? .holoError : .holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 12)
    }
}

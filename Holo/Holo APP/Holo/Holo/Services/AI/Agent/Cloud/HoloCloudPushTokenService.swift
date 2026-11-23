//
//  HoloCloudPushTokenService.swift
//  Holo
//
//  云端异步分析（二期）——「分析完成」推送的设备侧接线。
//  - AppDelegate 拿到 APNs token → 去重后上报后端（device_id ↔ token 绑定）
//  - 发起云端分析时请求通知权限并注册远程通知（权限拒绝不影响分析，只是收不到完成提醒）
//  - 模拟器直接跳过远程通知注册：其 token 非 64 位十六进制，后端 ^[0-9a-f]{64}$ 校验
//    必回 400，且模拟器收不到 Holo 推送（真实 APNs）。真机调试包 token 属 sandbox
//    环境，后端按 production→sandbox 回退探测后缓存直发
//

import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif
import os.log

#if canImport(UIKit)
@MainActor
final class HoloCloudPushTokenService {

    static let shared = HoloCloudPushTokenService()

    private let logger = Logger(subsystem: "com.holo.app", category: "CloudAnalysis")
    private let client: HoloCloudAnalysisClient
    private var lastReportedToken: String?
    private static let reportedTokenKey = "holo.cloudAnalysis.lastReportedPushToken"
    private static let reportedFailureReasonKey = "holo.cloudAnalysis.lastReportedPushTokenFailureReason"

    init(client: HoloCloudAnalysisClient? = nil) {
        self.client = client ?? HoloCloudAnalysisClient()
        lastReportedToken = UserDefaults.standard.string(forKey: Self.reportedTokenKey)
    }

    /// 发起云端分析时调用：请求通知授权（已决定过则立即返回），授权后注册远程通知。
    /// 注册结果经 AppDelegate 回调（didRegister/didFail），与 UI 无耦合。
    func requestAuthorizationAndRegister() {
        Task { @MainActor in
            _ = try? await TodoNotificationService.shared.requestAuthorization()
            // 产品埋点：授权弹窗返回瞬间记一次权限状态（冷启动另有快照，共用去重闸）
            await HoloProductAnalytics.shared.trackNotificationPermissionSnapshot()
            #if !targetEnvironment(simulator)
            // 模拟器跳过注册：其 token 非 64 位十六进制，后端 ^[0-9a-f]{64}$ 校验必回
            // 400（生产实证 7 天 561 次），且模拟器收不到 Holo 推送（真实 APNs）
            UIApplication.shared.registerForRemoteNotifications()
            #endif
        }
    }

    /// 启动期注册（2026-11-02 推送失联根治）：只注册远程通知、不弹授权询问。
    /// 此前注册只挂在「深度分析/周期回放」两个入口上，个性化规划等云端任务从不
    /// 注册；一旦某次令牌上报失败（lastReportedToken 只在成功后落盘），下次要再
    /// 碰到那两个入口才有重试机会——东林设备实证：10-31 用过回放+深度分析，服务器
    /// 始终无令牌，11-02 规划完成推送无处可发。改为每次启动注册：系统每次都会
    /// 回调最新 token，上报失败次日启动自动补报；授权弹窗时机仍留在业务入口。
    func registerRemoteNotifications() {
        Task { @MainActor in
            #if !targetEnvironment(simulator)
            // 模拟器跳过注册：其 token 非 64 位十六进制，后端 ^[0-9a-f]{64}$ 校验必回
            // 400（生产实证 7 天 561 次），且模拟器收不到 Holo 推送（真实 APNs）
            UIApplication.shared.registerForRemoteNotifications()
            #endif
        }
    }

    /// AppDelegate 回调：APNs token（hex）。与上次成功上报一致则跳过。
    func handleDeviceToken(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        guard token != lastReportedToken else { return }
        Task { @MainActor in
            do {
                try await client.registerDeviceToken(token)
                lastReportedToken = token
                UserDefaults.standard.set(token, forKey: Self.reportedTokenKey)
                // 成功后清掉已记的失败原因：之后的同因失败是新一轮问题，必须再报
                // （否则「失败→成功→同因失败」的第二次失败会被去重吞掉）
                UserDefaults.standard.removeObject(forKey: Self.reportedFailureReasonKey)
                logger.info("推送令牌已上报")
                // 产品埋点：令牌上报成功（与上次一致被去重跳过的重复上报不记）
                HoloProductAnalytics.shared.track(.pushTokenRegistered, ["result": "success"])
            } catch {
                // 上报失败不重试：下次启动注册回调会再触发（token 相同则跳过的去重
                // 只在成功后落盘，失败路径下次仍会重试）
                logger.error("推送令牌上报失败：\(String(describing: error), privacy: .public)")
                trackTokenFailureOnce(reason: String(describing: error))
            }
        }
    }

    /// AppDelegate 回调：注册失败（无 entitlement/网络）——静默，不影响云端分析链路
    func handleRegistrationFailure(_ error: Error) {
        logger.info("远程通知注册失败：\(String(describing: error), privacy: .public)")
        // 产品埋点：注册即失败（拿不到 token，上报更无从谈起）；与上次失败原因相同则去重跳过
        trackTokenFailureOnce(reason: String(describing: error))
    }

    /// 失败埋点去重：失败原因与上次已上报的相同则跳过（此前失败路径每次启动都重记，
    /// 生产实证 5 台模拟器单日 51 条）。原因截断到 200 字符再比较与存储；
    /// 上报成功会清掉已记原因，使之后的同因失败能再次上报。
    private func trackTokenFailureOnce(reason: String) {
        let trimmed = String(reason.prefix(200))
        guard trimmed != UserDefaults.standard.string(forKey: Self.reportedFailureReasonKey) else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.reportedFailureReasonKey)
        HoloProductAnalytics.shared.track(.pushTokenRegistered, [
            "result": "failed",
            "reason": trimmed,
        ])
    }
}

/// UIApplicationDelegate 最小实现：只为接收 APNs token 回调（SwiftUI App 无此回调入口）。
/// 其余生命周期（前台/后台）由 SwiftUI scenePhase 承担。
final class HoloPushAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            HoloCloudPushTokenService.shared.handleDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            HoloCloudPushTokenService.shared.handleRegistrationFailure(error)
        }
    }
}
#endif

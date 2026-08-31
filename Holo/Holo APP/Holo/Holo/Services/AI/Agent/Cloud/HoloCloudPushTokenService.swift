//
//  HoloCloudPushTokenService.swift
//  Holo
//
//  云端异步分析（二期）——「分析完成」推送的设备侧接线。
//  - AppDelegate 拿到 APNs token → 去重后上报后端（device_id ↔ token 绑定）
//  - 发起云端分析时请求通知权限并注册远程通知（权限拒绝不影响分析，只是收不到完成提醒）
//  - 模拟器不支持 APNs（didFailToRegister 静默），真机调试包 token 属 sandbox 环境，
//    后端按 production→sandbox 回退探测后缓存直发
//

import Foundation
import UserNotifications
import UIKit
import os.log

@MainActor
final class HoloCloudPushTokenService {

    static let shared = HoloCloudPushTokenService()

    private let logger = Logger(subsystem: "com.holo.app", category: "CloudAnalysis")
    private let client: HoloCloudAnalysisClient
    private var lastReportedToken: String?
    private static let reportedTokenKey = "holo.cloudAnalysis.lastReportedPushToken"

    init(client: HoloCloudAnalysisClient? = nil) {
        self.client = client ?? HoloCloudAnalysisClient()
        lastReportedToken = UserDefaults.standard.string(forKey: Self.reportedTokenKey)
    }

    /// 发起云端分析时调用：请求通知授权（已决定过则立即返回），授权后注册远程通知。
    /// 注册结果经 AppDelegate 回调（didRegister/didFail），与 UI 无耦合。
    func requestAuthorizationAndRegister() {
        Task { @MainActor in
            _ = try? await TodoNotificationService.shared.requestAuthorization()
            UIApplication.shared.registerForRemoteNotifications()
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
                logger.info("推送令牌已上报")
            } catch {
                // 上报失败不重试：下次启动注册回调会再触发（token 相同则跳过的去重
                // 只在成功后落盘，失败路径下次仍会重试）
                logger.error("推送令牌上报失败：\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// AppDelegate 回调：注册失败（模拟器/无 entitlement/网络）——静默，不影响云端分析链路
    func handleRegistrationFailure(_ error: Error) {
        logger.info("远程通知注册失败（模拟器属正常）：\(String(describing: error), privacy: .public)")
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

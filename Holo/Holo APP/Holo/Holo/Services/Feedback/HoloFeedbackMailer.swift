//
//  HoloFeedbackMailer.swift
//  Holo
//
//  用户反馈：邮件入口 + 设备信息自动填充 + 诊断日志附件。
//  收件人以官网为准：holoappservice@gmail.com
//

import Foundation
import MessageUI
import SwiftUI

enum HoloFeedbackMailer {

    /// 官网公布的反馈邮箱（隐私政策与用户协议同步使用此地址）。
    static let recipient = "holoappservice@gmail.com"

    // MARK: - 能力检测

    /// 当前设备是否配置了邮件账户。
    static var canSendMail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    // MARK: - 设备信息

    /// 生成预填到邮件正文的设备信息块。
    static func deviceInfoBlock() -> String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = UIDevice.current.systemVersion
        let deviceModel = UIDevice.current.model

        return """
        —————— 设备信息（请勿删除，用于问题定位）——————
        App 版本：\(appVersion) (\(buildNumber))
        设备：\(deviceModel)，iOS \(osVersion)
        反馈时间：\(Self.feedbackDateString())
        ————————————————————————————————

        请在下方描述你遇到的问题：


        """
    }

    // MARK: - 触发反馈

    /// 拉起邮件界面。若设备未配置邮件账户，返回 false（调用方降级提示）。
    /// - Parameter includeDiagnosticLog: 是否附上诊断日志（仅在用户从诊断页发起时为 true）。
    @discardableResult
    static func presentMail(includeDiagnosticLog: Bool = false) -> Bool {
        guard canSendMail else { return false }

        // 找到当前最顶层的 ViewController 来 present
        guard let rootVC = Self.topViewController() else { return false }

        let mailVC = MFMailComposeViewController()
        mailVC.mailComposeDelegate = HoloMailComposeDelegate.shared
        mailVC.setToRecipients([recipient])
        mailVC.setSubject("Holo 反馈")
        mailVC.setMessageBody(deviceInfoBlock(), isHTML: false)

        if includeDiagnosticLog {
            if let export = HoloDiagnosticLogger.shared.exportAllLogs(),
               let fileURL = export.fileURL,
               let data = try? Data(contentsOf: fileURL) {
                mailVC.addAttachmentData(
                    data,
                    mimeType: "text/plain",
                    fileName: "holo-diagnostic.txt"
                )
            }
        }

        rootVC.present(mailVC, animated: true)
        return true
    }
}

// MARK: - 邮件关闭回调

private final class HoloMailComposeDelegate: NSObject, MFMailComposeViewControllerDelegate {
    static let shared = HoloMailComposeDelegate()

    func mailComposeController(_ controller: MFMailComposeViewController,
                                didFinishWith result: MFMailComposeResult,
                                error: Error?) {
        controller.dismiss(animated: true)
    }
}

// MARK: - 辅助：定位顶层 ViewController

private extension HoloFeedbackMailer {
    static func topViewController(_ base: UIViewController? = nil) -> UIViewController? {
        let base = base ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?
            .rootViewController

        guard var current = base else { return nil }

        while let presented = current.presentedViewController {
            current = presented
        }

        // 处理 UINavigationController / UITabBarController 嵌套
        if let nav = current as? UINavigationController {
            return nav.visibleViewController ?? nav
        }
        if let tab = current as? UITabBarController {
            return tab.selectedViewController ?? tab
        }

        return current
    }

    static func feedbackDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

import UIKit
import AudioToolbox

/// 触觉反馈管理器 - 统一管理 App 内所有震动反馈
enum HapticManager {

    // MARK: - Notification Feedback（通知反馈）

    /// 成功 - 用于保存/创建/提交成功
    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    /// 警告 - 用于警告提示
    static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }

    /// 错误 - 用于操作失败
    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }

    // MARK: - Impact Feedback（撞击反馈）

    /// 轻量 - 用于轻微交互（计数+1、选择切换）
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 中等 - 用于中等交互（打卡、任务完成、长按触发）
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 重度 - 用于重要操作
    static func heavy() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    // MARK: - 任务完成

    /// 任务完成 - 系统音效 + 触觉反馈
    static func taskCompletion() {
        AudioServicesPlaySystemSound(1057)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Selection Feedback（选择反馈）

    /// 选择变化 - 用于拖拽排序、滑动选择
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

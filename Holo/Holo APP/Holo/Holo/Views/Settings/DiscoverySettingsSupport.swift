//
//  DiscoverySettingsSupport.swift
//  Holo
//
//  「一个发现」设置侧共享件：settingsDetailState 九态文案映射（01 §1 设置子页列）、
//  来源域展示元数据（想法/任务/习惯）。供 DiscoverySettingsView、HoloAIUserSettingsView、
//  DiscoveryFirstEnableSheet 共用。
//

import SwiftUI
import Combine

/// 「一个发现」设置状态的 SwiftUI 桥：把 DiscoveryService 的拉取模型
/// （plain var 快照）变成可观察发布，供统一设置页主条目摘要与子页共用同一份。
///
/// 服务协议没有变化回调（协调器非 ObservableObject，V1 拉取模型），所以本桥
/// 不猜变化时机：页面每次动作完成（开启/关闭/重置）后显式调 reload()，
/// onAppear 时也重拉一次——操作之后页面立即跟上，不再依赖重新进页。
@MainActor
final class DiscoverySettingsWatcher: ObservableObject {

    @Published private(set) var detailState: DiscoverySettingsDetailState
    /// 本机允许范围真源（开启时选定；修改需服务端 scope 语义，V1 只读展示）
    @Published private(set) var allowedDomains: Set<DiscoverySourceDomain>

    private let service: any DiscoveryService

    init(service: any DiscoveryService) {
        self.service = service
        self.detailState = service.settingsDetailState
        self.allowedDomains = DiscoverySettings.shared.snapshot().allowedDomains
    }

    /// 重拉服务状态与本机范围（纯读，无网络无副作用）
    func reload() {
        detailState = service.settingsDetailState
        allowedDomains = DiscoverySettings.shared.snapshot().allowedDomains
    }
}

/// 九态 → 设置页文案（主行 + 说明行）的唯一定义处
enum DiscoverySettingsCopy {

    /// 设置子页主状态文案（01 §1 状态表第 3 列）
    static func statusText(for state: DiscoverySettingsDetailState) -> String {
        switch state {
        case .disabled: return "已关闭，可开启"
        case .preparing: return "正在准备"
        case .waitingForMaterial: return "有足够依据时再呈现"
        case .hasFinding(viewed: false): return "有一个发现"
        case .hasFinding(viewed: true): return "已看，可重读"
        case .stale: return "等待新的线索"
        case .pausedTemporarily: return "暂未更新"
        case .revoked: return "已关闭 / 授权已撤回"
        case .serverUnsupported: return "暂不可用"
        }
    }

    /// 设置子页状态说明行（不催促、不暗示后台已分析）
    static func statusDetailText(for state: DiscoverySettingsDetailState) -> String {
        switch state {
        case .disabled:
            return "由你决定什么时候开启；开启前不会分析你的记录。"
        case .preparing:
            return "需要一些准备时间，不必在这里等待。"
        case .waitingForMaterial:
            return "记录不足或解释不可靠时不呈现，不保证每天更新。"
        case .hasFinding(viewed: false):
            return "已核对记录依据，等你想看时在对话页打开。"
        case .hasFinding(viewed: true):
            return "这条发现仍有效，可随时重读。"
        case .stale:
            return "上一条已过期或来源失效，等待新的线索。"
        case .pausedTemporarily:
            return "暂未更新，不需要你做任何操作。"
        case .revoked:
            return "数据处理授权已撤回；恢复总授权不会自动重新开启。"
        case .serverUnsupported:
            return "当前版本暂不支持，开关无法完成开启。"
        }
    }

    /// 统一设置页主条目行的副标题（比子页更简短的口径）
    static func summaryText(for state: DiscoverySettingsDetailState) -> String {
        switch state {
        case .disabled, .revoked: return "已关闭"
        case .preparing: return "正在准备"
        case .waitingForMaterial, .stale: return "等待新的线索"
        case .hasFinding: return "有一个发现"
        case .pausedTemporarily: return "暂未更新"
        case .serverUnsupported: return "暂不可用"
        }
    }

    /// 该状态下功能开关是否处于“开”（serverUnsupported 时开关不可完成开启，按关显示）
    static func isEnabledState(_ state: DiscoverySettingsDetailState) -> Bool {
        switch state {
        case .disabled, .revoked, .serverUnsupported: return false
        default: return true
        }
    }

    /// 开关行是否可交互（后端不支持时禁止开启）
    static func isToggleDisabled(_ state: DiscoverySettingsDetailState) -> Bool {
        state == .serverUnsupported
    }
}

/// 来源域（想法/任务/习惯）的展示元数据：首开多选与设置页「允许来源」共用
struct DiscoveryDomainMeta: Identifiable {
    let domain: DiscoverySourceDomain
    let title: String
    let subtitle: String
    let icon: String

    var id: String { domain.rawValue }

    static let all: [DiscoveryDomainMeta] = [
        DiscoveryDomainMeta(domain: .thought, title: "想法", subtitle: "你记下的想法与笔记正文", icon: "lightbulb"),
        DiscoveryDomainMeta(domain: .task, title: "任务", subtitle: "待办的创建与完成情况", icon: "checklist"),
        DiscoveryDomainMeta(domain: .habit, title: "习惯", subtitle: "习惯打卡记录", icon: "flame")
    ]
}

/// 「自动处理如何进行」说明子页：设置页的边界与透明度说明收进这里，
/// 主页保持轻（原型 discoverySettings 页即为一行入口）。
struct DiscoveryProcessingNoteView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                bullet("有新材料时，Holo 自动把你允许范围内的必要片段，通过 Holo 后端交给第三方 AI 理解并核验；不承诺只在本地推理。", icon: "arrow.triangle.branch")
                bullet("先有依据、再呈现：记录不足或解释不可靠时不展示；呈现的发现都附可打开的记录依据。", icon: "checkmark.shield")
                bullet("不承诺每日、实时或一定有发现；不发通知、不打扰。", icon: "bell.slash")
                bullet("关闭即停止：取消未完成任务并删除派生内容；已发出的请求尽力取消，迟到结果不再采纳。", icon: "stop.circle")
                bullet("不读取长期记忆，也不写入长期记忆。", icon: "brain")
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoToolBackground.ignoresSafeArea())
        .navigationTitle("自动处理如何进行")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.discovery.processingNote")
    }

    private func bullet(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

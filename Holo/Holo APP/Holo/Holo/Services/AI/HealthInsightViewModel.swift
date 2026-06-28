//
//  HealthInsightViewModel.swift
//  Holo
//
//  健康洞察 UI 状态：管理加载、刷新、缓存命中、错误回退。
//  页面加载时先显示缓存或 fallback，异步触发生成（方案 Task 8）。
//

import SwiftUI

@MainActor
@Observable
final class HealthInsightViewModel {

    private let service: HealthInsightGenerationService
    private let cache: HealthInsightCache

    private(set) var snapshot: GeneratedHealthInsightSnapshot?
    private(set) var isLoading = false

    init(service: HealthInsightGenerationService? = nil, cache: HealthInsightCache = .shared) {
        if let service {
            self.service = service
        } else {
            self.service = HealthInsightGenerationService(
                contextBuilder: HealthInsightContextBuilder(dataSource: HoloHealthInsightDataSource()),
                provider: HoloBackendAIProvider()
            )
        }
        self.cache = cache
    }

    /// 生成状态文案（1.1：生成中 / 今日已更新 / 数据不足 / 使用本地兜底）。
    var statusText: String {
        switch snapshot?.status {
        case .fresh, .cached: return "今日已更新"
        case .insufficientData: return "数据不足"
        case .fallback: return "使用本地兜底"
        case .generating: return "生成中"
        case .disabled, nil: return ""
        }
    }

    /// 页面加载：先缓存后按需生成。
    func load(now: Date = Date()) async {
        isLoading = true
        defer { isLoading = false }
        snapshot = await service.load(now: now)
    }

    /// 手动刷新：受每天 3 次与失败节流限制（方案 6.3）。
    func refresh(now: Date = Date()) async {
        guard cache.canManualRefresh(now: now) else { return }
        cache.recordManualRefresh(now: now)
        await load(now: now)
    }

    /// 手动刷新是否可用（UI 按钮禁用判断）。
    func canRefresh(now: Date = Date()) -> Bool {
        cache.canManualRefresh(now: now)
    }
}

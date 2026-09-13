//
//  HoloMatter+ProjectionAccessor.swift
//  Holo
//
//  Matter 投影便捷访问器（仅主 app；widget target 不依赖投影 DTO）
//

import Foundation

extension HoloMatter {

    /// 当前投影。损坏或版本不识别时返回 nil（UI 走确定性降级，不崩）。
    var projection: HoloMatterProjectionV1? {
        get { HoloMatterProjectionV1.decode(from: projectionJSON, matterRevision: revision) }
        set { projectionJSON = newValue?.encodeJSON() }
    }

    /// 投影是否落后于 canonical 状态。
    var isProjectionStale: Bool {
        guard let projection else { return true }
        return projection.isStale(currentRevision: revision)
    }
}

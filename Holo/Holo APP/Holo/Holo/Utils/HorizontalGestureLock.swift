//
//  HorizontalGestureLock.swift
//  Holo
//
//  全局横向手势方向锁定
//

import CoreGraphics

enum GestureAxisLock: Equatable {
    case undecided
    case horizontal
    case vertical
}

struct HorizontalGestureTuning {
    static let global = HorizontalGestureTuning()

    /// 小于该距离时保持观望，避免轻触和滚动起步阶段误判。
    let touchSlop: CGFloat
    /// 横向确认距离。保持偏小，确认后直接使用累计位移，减少左滑卡顿感。
    let horizontalConfirmDistance: CGFloat
    /// 纵向确认距离。略低于日历/列表切换阈值，让垂直滚动更早接管。
    let verticalConfirmDistance: CGFloat
    /// 主方向需比副方向明显强多少才锁定，避免 45 度附近来回争抢。
    let directionDominanceRatio: CGFloat

    init(
        touchSlop: CGFloat = 6,
        horizontalConfirmDistance: CGFloat = 12,
        verticalConfirmDistance: CGFloat = 10,
        directionDominanceRatio: CGFloat = 1.12
    ) {
        self.touchSlop = touchSlop
        self.horizontalConfirmDistance = horizontalConfirmDistance
        self.verticalConfirmDistance = verticalConfirmDistance
        self.directionDominanceRatio = directionDominanceRatio
    }
}

struct HorizontalGestureLock {
    private(set) var axis: GestureAxisLock = .undecided
    private let tuning: HorizontalGestureTuning

    init(tuning: HorizontalGestureTuning = .global) {
        self.tuning = tuning
    }

    mutating func reset() {
        axis = .undecided
    }

    @discardableResult
    mutating func update(translation: CGPoint) -> GestureAxisLock {
        update(translation: CGSize(width: translation.x, height: translation.y))
    }

    @discardableResult
    mutating func update(translation: CGSize) -> GestureAxisLock {
        guard axis == .undecided else { return axis }

        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        guard max(horizontal, vertical) >= tuning.touchSlop else { return .undecided }

        if horizontal >= tuning.horizontalConfirmDistance,
           horizontal >= vertical * tuning.directionDominanceRatio {
            axis = .horizontal
            return axis
        }

        if vertical >= tuning.verticalConfirmDistance,
           vertical >= horizontal * tuning.directionDominanceRatio {
            axis = .vertical
            return axis
        }

        return .undecided
    }
}

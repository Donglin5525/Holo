//
//  HoloLog.swift
//  Holo
//
//  日志通道常量：subsystem 此前以字符串字面量散落 160+ 处，收敛到单一事实源（体检 R0-42）
//

import Foundation

enum HoloLog {
    /// 统一日志 subsystem； category 由各模块自定
    static let subsystem = "com.holo.app"
}

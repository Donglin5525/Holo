//
//  TestHostEnvironment.swift
//  Holo
//
//  hosted test（测试注入 app 进程）环境判定。
//  XCTest 把 HoloTests 注入 Holo.app 运行时，app 只需提供活着的主线程与 bundle；
//  业务 UI 与后台服务照常启动会与测试 task 并发交互，触发 Swift Concurrency
//  运行时已知 double-free（见 docs/_common/notes/2026-07-17-XCTest内存CoreData与通知崩溃.md 坑2/坑3）。
//

import Foundation

enum TestHostEnvironment {
    /// 当前进程是否作为 XCTest 宿主运行（模拟器 hosted test 注入后进程名仍是 Holo）。
    static let isHostedByXCTest: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }()
}

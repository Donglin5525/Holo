//
//  ChatOpenPerfProbe.swift
//  Holo
//
//  聊天页「打开链路」分段计时探针（2026-11-05 对齐微信级打开体感 · 第 0 档取证）
//
//  为什么存在：聊天页打开路径此前没有任何分段计时，卡顿只能靠体感与
//  MetricKit HangDiagnostics（≥250ms 才生成）事后取证。本探针把一次「进入
//  聊天页」从 ChatView 挂载 .task 开始、到首屏 reveal 为止的关键节点逐段落盘，
//  后续治理（首帧布局、页面常驻化、列表窗口化）以这里的真实耗时分布为依据。
//
//  数据出口：Documents/ChatOpenPerf/chat-open.jsonl，每行一次打开的 JSON：
//    { "ts": ..., "openMs": 483, "firstRowMs": 210, "publishes": 1,
//      "messages": 24, "marks": { "setupDone": 35, "fetchDone": 120, ... } }
//  文件超 256KB 滚动归档为 chat-open.old.jsonl；落盘在独立低优先级队列串行，
//  任何失败静默，绝不反向影响主流程。
//  关闭开关：UserDefaults "holo.chatOpenPerf.disabled" = true。
//

import Foundation

@MainActor
final class ChatOpenPerfProbe {
    static let shared = ChatOpenPerfProbe()

    private struct OpenRecord {
        var startedAt: CFAbsoluteTime
        var marks: [(name: String, at: CFAbsoluteTime)] = []
        var publishCount = 0
        var messageCount = 0
        var firstRowAt: CFAbsoluteTime?
    }

    private var record: OpenRecord?
    private var autoFlushTask: Task<Void, Never>?
    private let ioQueue = DispatchQueue(label: "holo.chat-open-perf", qos: .utility)

    /// reveal 之外的兜底收尾时限：内容层可能因授权未开/服务未配置而从未挂载
    /// （reveal 任务在 ChatContentColumn 内），或用户快速退出页面。
    /// 到点仍未收尾就按 timeout 落盘，杜绝「只开始不收尾」的哑记录。
    private static let autoFlushInterval: TimeInterval = 15

    private static let directoryURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ChatOpenPerf", isDirectory: true)
    private static let fileURL = directoryURL.appendingPathComponent("chat-open.jsonl")
    private static let archiveURL = directoryURL.appendingPathComponent("chat-open.old.jsonl")
    private static let maxFileBytes = 256 * 1024

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private var disabled: Bool {
        UserDefaults.standard.bool(forKey: "holo.chatOpenPerf.disabled")
    }

    /// 一次打开的起点（ChatView 首次挂载的 .task）。上一轮未收尾的记录由自动
    /// 收尾兜底或此处丢弃（页面被快速退出等场景），不落半截数据。
    func beginOpen() {
        guard !disabled else { return }
        autoFlushTask?.cancel()
        record = OpenRecord(startedAt: CFAbsoluteTimeGetCurrent())
        let deadline = Self.autoFlushInterval
        autoFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            guard !Task.isCancelled else { return }
            self?.endOpen(settled: "timeout")
        }
    }

    /// 记录一个阶段完成时刻；相对起点的毫秒在 endOpen 统一换算。
    /// 同名标记后到先覆盖（编码时取最后一次）。
    func mark(_ name: String) {
        guard record != nil else { return }
        record?.marks.append((name, CFAbsoluteTimeGetCurrent()))
    }

    /// 打开窗口内每次 messages 整组发布 +1（发布次数 = 全列表重算次数）
    func noteMessagePublish(count: Int) {
        guard var current = record else { return }
        current.publishCount += 1
        current.messageCount = max(current.messageCount, count)
        record = current
    }

    /// 首行消息真实进入屏幕的时刻（首帧列表布局完成的最接近信号）
    func noteFirstRowAppeared() {
        guard record != nil, record?.firstRowAt == nil else { return }
        record?.firstRowAt = CFAbsoluteTimeGetCurrent()
    }

    /// 打开终点：首屏 reveal（isInitialConversationVisible 置 true 处调用）；
    /// 超时兜底走 settled = "timeout"。
    func endOpen(settled: String = "reveal") {
        guard let finished = record else { return }
        record = nil
        autoFlushTask?.cancel()
        let endAt = CFAbsoluteTimeGetCurrent()
        encodeAndFlush(finished, endAt: endAt, settled: settled)
    }

    // MARK: - 落盘

    private func encodeAndFlush(_ record: OpenRecord, endAt: CFAbsoluteTime, settled: String) {
        var payload: [String: Any] = [
            "ts": Self.timestampFormatter.string(from: Date()),
            "openMs": Int((endAt - record.startedAt) * 1000),
            "settled": settled,
            "publishes": record.publishCount,
            "messages": record.messageCount,
        ]
        if let firstRowAt = record.firstRowAt {
            payload["firstRowMs"] = Int((firstRowAt - record.startedAt) * 1000)
        }
        var marksPayload: [String: Int] = [:]
        for entry in record.marks {
            marksPayload[entry.name] = Int((entry.at - record.startedAt) * 1000)
        }
        if !marksPayload.isEmpty {
            payload["marks"] = marksPayload
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        ), let line = String(data: data, encoding: .utf8) else { return }
        ioQueue.async { Self.appendLine(line) }
    }

    /// 独立队列串行追加；超限滚动归档（old 覆盖旧 old）。
    private nonisolated static func appendLine(_ line: String) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true
            )
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int
            if let size, size > maxFileBytes {
                try? FileManager.default.removeItem(at: archiveURL)
                try? FileManager.default.moveItem(at: fileURL, to: archiveURL)
            }
            // FileHandle(forWritingTo:) 不会创建新文件：首写前必须先落一个空文件，
            // 否则初始化抛错、本轮记录被静默丢弃（模拟器冒烟实抓）。
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = (line + "\n").data(using: .utf8) {
                handle.write(data)
            }
        } catch {
            // 取证装置自身失败静默
        }
    }
}

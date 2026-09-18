//
//  GoalWorkshopServiceFactory.swift
//  Holo
//
//  目标共创模型服务工厂：生产=后端 goal_workshop purpose；
//  DEBUG 下支持 GOAL_WORKSHOP_UI_MOCK 启动参数切换为本地脚本回声
//  （UI 走查/自动化用，不依赖网络与后端发版）。
//

import Foundation

enum GoalWorkshopServiceFactory {

    static func make() -> GoalWorkshopModelServicing {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("GOAL_WORKSHOP_UI_MOCK") {
            return GoalWorkshopScriptedMockService()
        }
        #endif
        guard let provider = HoloBackendEnvironment.makeDefaultProvider() as? GoalWorkshopModelServicing else {
            return GoalWorkshopUnavailableService()
        }
        return provider
    }
}

/// 生产兜底：默认 Provider 不是 Holo 后端时（理论不可达），明确报错不静默
struct GoalWorkshopUnavailableService: GoalWorkshopModelServicing {
    func sendGoalWorkshop(_ bodyJSON: String) async throws -> String {
        throw GoalWorkshopCoordinatorError.invalidModelOutput("当前 Provider 不支持 goal_workshop purpose")
    }
}

#if DEBUG
/// 本地脚本回声：understand→问一题；propose_options→两条路径；build_plan→草案。
/// 回显请求 sessionID/revision，供 UI 测试走完整旅程。
struct GoalWorkshopScriptedMockService: GoalWorkshopModelServicing {
    func sendGoalWorkshop(_ bodyJSON: String) async throws -> String {
        guard let data = bodyJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionID = object["sessionID"] as? String,
              let revision = object["revision"] as? Int,
              let operation = object["operation"] as? String else {
            throw GoalWorkshopCoordinatorError.invalidModelOutput("脚本请求体不合法")
        }
        switch operation {
        case "propose_options":
            return """
            {"schemaVersion":1,"sessionID":"\(sessionID)","revision":\(revision),"kind":"options","assistantText":"两条路给你选","question":null,"options":[{"id":"route-1","title":"先练会议听说","fit":"近期有真实会议","effort":"每天20分钟","tradeoff":"基础需边用边补","reason":"贴近当前用途"},{"id":"route-2","title":"先补语言基础","fit":"近期没有会议压力","effort":"每天20分钟","tradeoff":"进入真实会议较慢","reason":"先减少基础障碍"}],"recommendedOptionID":"route-1","plan":null,"facts":null}
            """
        case "build_plan":
            return """
            {"schemaVersion":1,"sessionID":"\(sessionID)","revision":\(revision),"kind":"plan","assistantText":"初稿好了","question":null,"options":null,"recommendedOptionID":null,"plan":{"draft":{"id":"draft-1","title":"工作会议英语敢开口","summary":null,"domain":"learning","iconEmoji":null,"desiredOutcome":"周会发言一次","motivation":null,"deadlineText":"2026-12-31","tasks":[{"id":"task-1","isSelected":true,"title":"准备英文自我介绍","dueDateText":"2026-09-25","priority":1,"note":null}],"habits":[{"id":"habit-1","isSelected":true,"name":"跟读会议录音","frequency":"daily","targetCount":1,"type":"checkIn","unit":null,"targetValue":null,"isBadHabit":false,"successRule":"completeWhenDone"}],"missingInfoWarnings":[]},"successEvidence":"连续四周周会发言","milestones":[{"id":"m-1","title":"首次英文发言","dateText":"2026-10-31"}],"firstActionID":"task-1","assumptions":["每周有英文会"],"reviewDate":"2026-10-15"},"facts":null}
            """
        default:
            return """
            {"schemaVersion":1,"sessionID":"\(sessionID)","revision":\(revision),"kind":"question","assistantText":"我理解你的想法","question":{"text":"这件事最近的真实场景是什么时候？","whyItMatters":"场景与频率决定路径取舍"},"options":null,"recommendedOptionID":null,"plan":null,"facts":[{"id":"f-1","text":"推断：有明确场景","provenance":"inference"}]}
            """
        }
    }
}
#endif

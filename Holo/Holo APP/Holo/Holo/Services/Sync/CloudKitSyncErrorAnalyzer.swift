//
//  CloudKitSyncErrorAnalyzer.swift
//  Holo
//
//  NSPersistentCloudKitContainer 事件错误解析
//  iCloud 存储满（quotaExceeded）常被包在 partialFailure 或底层 NSError 里，
//  必须逐层拆开识别，否则会被当成普通网络错误吞掉，用户看到的是「假成功」。
//

import Foundation
import CloudKit

nonisolated enum CloudKitSyncErrorAnalyzer {

    enum FailureKind: Equatable {
        /// iCloud 存储空间已满：重试解决不了，需要用户清理空间，须专门提示
        case quotaExceeded
        /// 系统取消（切后台/锁屏/断网中断）：正常现象，自动重试，不算失败
        case operationCancelled
        case other
    }

    static func classify(_ error: Error) -> FailureKind {
        if isOperationCancelled(error) { return .operationCancelled }
        if containsQuotaExceeded(error) { return .quotaExceeded }
        return .other
    }

    static func isOperationCancelled(_ error: Error) -> Bool {
        if let ckError = error as? CKError, ckError.code == .operationCancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == CKErrorDomain
            && CKError.Code(rawValue: nsError.code) == .operationCancelled
    }

    /// 逐层查找配额超限：直接 CKError → partialFailure 的逐条子错误 → underlyingError 链
    static func containsQuotaExceeded(_ error: Error, depth: Int = 0) -> Bool {
        guard depth < 5 else { return false }

        if let ckError = error as? CKError, ckError.code == .quotaExceeded {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == CKErrorDomain,
           CKError.Code(rawValue: nsError.code) == .quotaExceeded {
            return true
        }

        if nsError.domain == CKErrorDomain,
           CKError.Code(rawValue: nsError.code) == .partialFailure,
           let partials = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            for partial in partials.values where containsQuotaExceeded(partial, depth: depth + 1) {
                return true
            }
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return containsQuotaExceeded(underlying, depth: depth + 1)
        }

        return false
    }

    /// 取最深层 CloudKit 错误码（诊断流水展示用；非 CloudKit 错误返回 nil）
    static func deepestCKErrorCode(_ error: Error, depth: Int = 0) -> Int? {
        guard depth < 5 else { return nil }
        let nsError = error as NSError

        if nsError.domain == CKErrorDomain,
           CKError.Code(rawValue: nsError.code) == .partialFailure,
           let partials = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            for partial in partials.values {
                if let code = deepestCKErrorCode(partial, depth: depth + 1) {
                    return code
                }
            }
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           let code = deepestCKErrorCode(underlying, depth: depth + 1) {
            return code
        }

        return nsError.domain == CKErrorDomain ? nsError.code : nil
    }
}

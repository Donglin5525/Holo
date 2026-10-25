//
//  HoloMemoryRepository+UserControlRestore.swift
//  Holo
//
//  用户恢复专用的墓碑清理（方案 §11.5：恢复只允许走专门业务 API，
//  deleteTombstoneForMigration 不得被业务调用方直接使用——本包装是唯一例外出口）。
//

import Foundation

extension HoloMemoryRepository {
    /// 恢复/撤销停用时解除该记录的用户控制墓碑。幂等：墓碑不存在时静默成功。
    func clearUserControlTombstone(recordID: String) async throws {
        guard try await fetchTombstone(identityKey: recordID) != nil else { return }
        try await deleteTombstoneForMigration(identityKey: recordID)
    }
}

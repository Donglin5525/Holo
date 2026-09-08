//
//  HoloMemoryForgettingStore.swift
//  Holo
//
//  用户忘记、清空、重新扫描历史与原始数据联动的唯一写入口。
//

import Foundation

protocol HoloMemoryForgettingStore: Sendable {
    func fetch(id: String) async throws -> HoloMemoryRecord?
    func query(_ query: HoloMemoryRepositoryQuery) async throws -> [HoloMemoryRecord]
    func markUserDecision(
        id: String,
        decision: HoloMemoryUserDecision,
        now: Date
    ) async throws -> Bool
    func loadControlState() async throws -> HoloMemoryControlState
    func saveControlState(_ state: HoloMemoryControlState) async throws
    func saveTombstone(_ tombstone: HoloMemoryTombstone) async throws
    func replaceRecordForUserControl(_ record: HoloMemoryRecord) async throws
}

#if !HOLO_MEMORY_STANDALONE
extension CoreDataHoloMemoryRepository: HoloMemoryForgettingStore {}
#endif


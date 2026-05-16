//
//  FinanceCategoryCatalogCache.swift
//  Holo
//
//  标准财务科目 catalog 的本地持久缓存。
//

import Foundation

@MainActor
final class FinanceCategoryCatalogCache {
    static let shared = FinanceCategoryCatalogCache()

    private let catalogKey = "com.holo.financeCategoryCatalog.content"
    private let versionKey = "com.holo.financeCategoryCatalog.version"

    private init() {}

    func load() -> FinanceCategoryCatalog? {
        guard let data = UserDefaults.standard.data(forKey: catalogKey) else {
            return nil
        }
        return try? JSONDecoder().decode(FinanceCategoryCatalog.self, from: data)
    }

    func save(_ catalog: FinanceCategoryCatalog) {
        guard let data = try? JSONEncoder().encode(catalog) else {
            return
        }
        UserDefaults.standard.set(data, forKey: catalogKey)
        UserDefaults.standard.set(catalog.version, forKey: versionKey)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: catalogKey)
        UserDefaults.standard.removeObject(forKey: versionKey)
    }
}

//
//  ImportCategoryPlanner.swift
//  Holo
//
//  导入分类规划：导入文件中的科目即用户真实科目，只做精确复用和原样创建
//

import Foundation

struct ImportCategoryDescriptor: Hashable, Identifiable {
    let typeRaw: String
    let primaryName: String
    let subName: String?

    var id: String { key }

    var normalizedPrimaryName: String {
        primaryName.trimmingCharacters(in: .whitespaces)
    }

    var normalizedSubName: String? {
        subName?.trimmingCharacters(in: .whitespaces)
    }

    var primaryKey: String {
        "\(typeRaw)|\(normalizedPrimaryName)"
    }

    var key: String {
        guard let normalizedSubName, !normalizedSubName.isEmpty else {
            return primaryKey
        }
        return "\(primaryKey)|\(normalizedSubName)"
    }

    var topLevelDescriptor: ImportCategoryDescriptor {
        ImportCategoryDescriptor(typeRaw: typeRaw, primaryName: normalizedPrimaryName, subName: nil)
    }
}

struct ImportCategoryPlan {
    var reusedLeafCategoryKeys: Set<String>
    var primaryCategoriesToCreate: [ImportCategoryDescriptor]
    var subCategoriesToCreate: [ImportCategoryDescriptor]

    static let empty = ImportCategoryPlan(
        reusedLeafCategoryKeys: [],
        primaryCategoriesToCreate: [],
        subCategoriesToCreate: []
    )
}

enum ImportCategoryPlanner {

    static func makePlan(
        incoming: [ImportCategoryDescriptor],
        existing: [ImportCategoryDescriptor]
    ) -> ImportCategoryPlan {
        var existingPrimaryKeys = Set<String>()
        var existingLeafKeys = Set<String>()

        for descriptor in existing {
            if descriptor.normalizedSubName == nil {
                existingPrimaryKeys.insert(descriptor.primaryKey)
            } else {
                existingLeafKeys.insert(descriptor.key)
            }
        }

        var plannedPrimaryKeys = Set<String>()
        var plannedSubKeys = Set<String>()
        var reusedLeafKeys = Set<String>()
        var primaryCreates: [ImportCategoryDescriptor] = []
        var subCreates: [ImportCategoryDescriptor] = []

        for descriptor in incoming {
            let primary = descriptor.topLevelDescriptor
            if !existingPrimaryKeys.contains(primary.primaryKey),
               !plannedPrimaryKeys.contains(primary.primaryKey) {
                plannedPrimaryKeys.insert(primary.primaryKey)
                primaryCreates.append(primary)
            }

            guard let subName = descriptor.normalizedSubName, !subName.isEmpty else {
                continue
            }

            if subName == descriptor.normalizedPrimaryName {
                if existingPrimaryKeys.contains(primary.primaryKey) {
                    reusedLeafKeys.insert(primary.primaryKey)
                }
                continue
            }

            if existingLeafKeys.contains(descriptor.key) {
                reusedLeafKeys.insert(descriptor.key)
            } else if !plannedSubKeys.contains(descriptor.key) {
                plannedSubKeys.insert(descriptor.key)
                subCreates.append(descriptor)
            }
        }

        return ImportCategoryPlan(
            reusedLeafCategoryKeys: reusedLeafKeys,
            primaryCategoriesToCreate: primaryCreates,
            subCategoriesToCreate: subCreates
        )
    }

    /// 从扫描期收集的字符串集合生成计划（不查已存在分类，全部算作"将新建"）
    ///
    /// 供 scanCSV 使用：扫描阶段不知道用户的已有分类列表，只统计文件里有哪些科目，
    /// 全部视为需要新建。真实的"精确复用 vs 新建"判断在 ViewModel 拿到已有分类后做。
    static func makePlanFromDescriptors(
        incomingPrimaries: [String],
        incomingSubs: [String]
    ) -> ImportCategoryPlan {
        var plannedPrimaryKeys = Set<String>()
        var plannedSubKeys = Set<String>()
        var primaryCreates: [ImportCategoryDescriptor] = []
        var subCreates: [ImportCategoryDescriptor] = []

        // 先从 primaries 构建一级
        for raw in incomingPrimaries {
            let parts = raw.components(separatedBy: "|")
            guard parts.count >= 2 else { continue }
            let descriptor = ImportCategoryDescriptor(typeRaw: parts[0], primaryName: parts[1], subName: nil)
            if !plannedPrimaryKeys.contains(descriptor.primaryKey) {
                plannedPrimaryKeys.insert(descriptor.primaryKey)
                primaryCreates.append(descriptor)
            }
        }

        // 再从 subs 构建二级（跳过"sub == primary"的退化情况）
        for raw in incomingSubs {
            let parts = raw.components(separatedBy: "|")
            guard parts.count >= 3 else { continue }
            let typeRaw = parts[0]
            let primary = parts[1]
            let sub = parts[2]

            // 确保一级已纳入
            let primaryDesc = ImportCategoryDescriptor(typeRaw: typeRaw, primaryName: primary, subName: nil)
            if !plannedPrimaryKeys.contains(primaryDesc.primaryKey) {
                plannedPrimaryKeys.insert(primaryDesc.primaryKey)
                primaryCreates.append(primaryDesc)
            }

            // sub 与 primary 相同时跳过（不算独立二级）
            if sub == primary { continue }

            let descriptor = ImportCategoryDescriptor(typeRaw: typeRaw, primaryName: primary, subName: sub)
            if !plannedSubKeys.contains(descriptor.key) {
                plannedSubKeys.insert(descriptor.key)
                subCreates.append(descriptor)
            }
        }

        return ImportCategoryPlan(
            reusedLeafCategoryKeys: [],
            primaryCategoriesToCreate: primaryCreates,
            subCategoriesToCreate: subCreates
        )
    }
}

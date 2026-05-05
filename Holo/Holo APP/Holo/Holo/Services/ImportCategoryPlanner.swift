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
}

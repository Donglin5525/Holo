//
//  FinanceCategoryCatalog.swift
//  Holo
//
//  后端托管的标准财务科目对照表。
//

import Foundation

struct FinanceCategoryCatalog: Codable, Equatable, Sendable {
    let version: Int
    let expense: [FinanceCategoryGroup]
    let income: [FinanceCategoryGroup]

    var flattenedRows: [FinanceCategoryCatalogRow] {
        expense.flatMap { group in
            group.children.map {
                FinanceCategoryCatalogRow(
                    type: .expense,
                    primaryCategory: group.name,
                    subCategory: $0.name,
                    aliases: $0.aliases,
                    tags: $0.tags
                )
            }
        } + income.flatMap { group in
            group.children.map {
                FinanceCategoryCatalogRow(
                    type: .income,
                    primaryCategory: group.name,
                    subCategory: $0.name,
                    aliases: $0.aliases,
                    tags: $0.tags
                )
            }
        }
    }
}

struct FinanceCategoryGroup: Codable, Equatable, Sendable {
    let name: String
    let children: [FinanceCategoryLeaf]
}

struct FinanceCategoryLeaf: Codable, Equatable, Sendable {
    let name: String
    let aliases: [String]
    let tags: [String]
}

struct FinanceCategoryCatalogRow: Equatable, Sendable {
    let type: TransactionType
    let primaryCategory: String
    let subCategory: String
    let aliases: [String]
    let tags: [String]
}

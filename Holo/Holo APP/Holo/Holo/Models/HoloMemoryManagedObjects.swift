//
//  HoloMemoryManagedObjects.swift
//  Holo
//
//  统一记忆 Repository 的 Core Data 持久化对象
//

import CoreData
import Foundation

@objc(HoloMemoryRecordMO)
final class HoloMemoryRecordMO: NSManagedObject {
    @NSManaged var stableID: String
    @NSManaged var recordVersion: Int64
    @NSManaged var scope: String
    @NSManaged var state: String
    @NSManaged var userDecision: String
    @NSManaged var hasHealthLineage: Bool
    @NSManaged var lastObservationKey: String?
    @NSManaged var recordData: Data
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
}

@objc(HoloMemoryEvidenceMO)
final class HoloMemoryEvidenceMO: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var recordID: String
    @NSManaged var lineageKey: String
    @NSManaged var evidenceData: Data
    @NSManaged var observedAt: Date
}

@objc(HoloMemoryAnchorAliasMO)
final class HoloMemoryAnchorAliasMO: NSManagedObject {
    @NSManaged var aliasKey: String
    @NSManaged var anchorData: Data
    @NSManaged var verificationSource: String
    @NSManaged var verifiedAt: Date
}

@objc(HoloMemoryObservationRunMO)
final class HoloMemoryObservationRunMO: NSManagedObject {
    @NSManaged var observationKey: String
    @NSManaged var domain: String
    @NSManaged var status: String
    @NSManaged var extractorVersion: Int64
    @NSManaged var promptVersion: Int64
    @NSManaged var completedAt: Date
}

@objc(HoloMemoryTombstoneMO)
final class HoloMemoryTombstoneMO: NSManagedObject {
    @NSManaged var identityKey: String
    @NSManaged var scope: String
    @NSManaged var claimKind: String
    @NSManaged var anchorKeysJSON: String
    @NSManaged var userDecisionVersion: Int64
    @NSManaged var createdAt: Date
}

@objc(HoloMemoryControlStateMO)
final class HoloMemoryControlStateMO: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var stateData: Data
    @NSManaged var userDecisionVersion: Int64
    @NSManaged var updatedAt: Date
}

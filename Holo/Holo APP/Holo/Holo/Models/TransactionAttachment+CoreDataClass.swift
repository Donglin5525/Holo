//
//  TransactionAttachment+CoreDataClass.swift
//  Holo
//
//  票根实体类（交易照片附件）
//

import Foundation
import CoreData

@objc(TransactionAttachment)
public class TransactionAttachment: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<TransactionAttachment> {
        NSFetchRequest<TransactionAttachment>(entityName: "TransactionAttachment")
    }

    // MARK: - @NSManaged Properties

    @NSManaged public var id: UUID
    @NSManaged public var fileName: String
    @NSManaged public var thumbnailFileName: String
    @NSManaged public var sortOrder: Int16
    @NSManaged public var sourceType: String
    @NSManaged public var createdAt: Date
    @NSManaged public var imageData: Data?
    @NSManaged public var thumbnailData: Data?

    // MARK: - Relationships

    @NSManaged public var transaction: Transaction?
}

// MARK: - 来源类型

extension TransactionAttachment {

    /// 票根来源（为后续「AI 看照片」预留来源语义）
    enum AttachmentSource: String {
        case photoLibrary
        case camera
        case receiptBooking
    }

    var source: AttachmentSource {
        AttachmentSource(rawValue: sourceType) ?? .photoLibrary
    }
}

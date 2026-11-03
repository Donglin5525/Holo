import CoreData
import Foundation

extension FinanceRepository {
    func categoryParentRepairPreviews(type: TransactionType) throws -> [CategoryParentRepairPreview] {
        try CategoryParentRepairService.previews(in: context, type: type.rawValue)
    }

    func repairCategoryParent(_ preview: CategoryParentRepairPreview,
                              target: CategoryParentRepairTarget) async throws {
        guard let coordinator = context.persistentStoreCoordinator else {
            throw FinanceCategoryIntegrityError.dataChanged
        }
        let worker = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        worker.persistentStoreCoordinator = coordinator
        worker.mergePolicy = NSErrorMergePolicy
        worker.transactionAuthor = "finance.categoryParentRepair"
        let updatedIDs = try await worker.perform {
            try CategoryParentRepairService.apply(preview, to: target, in: worker)
        }
        for id in updatedIDs {
            if let object = context.registeredObject(for: id), !object.isDeleted {
                context.refresh(object, mergeChanges: true)
            }
        }
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }
}

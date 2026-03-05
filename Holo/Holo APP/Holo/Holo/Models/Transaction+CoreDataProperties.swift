//
//  Transaction+CoreDataProperties.swift
//  Holo
//
//  交易记录扩展 - 静态方法
//

import Foundation
import CoreData

extension Transaction {
    
    /// 创建 fetch request
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Transaction> {
        return NSFetchRequest<Transaction>(entityName: "Transaction")
    }
}
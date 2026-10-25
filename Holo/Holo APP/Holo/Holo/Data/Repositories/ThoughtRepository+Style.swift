import CoreData

extension ThoughtRepository {
    /// 分享面板的显式「设为本条样式」：只存外观，不重写正文、不触发 AI 整理。
    func updateStyle(_ style: ThoughtStyle, thoughtId: UUID) throws {
        guard let thought = try fetchById(thoughtId) else { throw ThoughtError.notFound }
        guard thought.appearanceRaw != style.storedValue else { return }
        let previous = thought.appearanceRaw
        let previousDate = thought.updatedAt
        thought.appearanceRaw = style.storedValue
        thought.updatedAt = Date()
        do {
            try context.save()
        } catch {
            // 失败只还原本次外观修改，不能 rollback 整个上下文卷走其他编辑。
            thought.appearanceRaw = previous
            thought.updatedAt = previousDate
            throw error
        }
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
    }
}

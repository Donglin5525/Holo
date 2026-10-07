# Findings: 财务分类删除与引用治理重构

## 用户需求

- 分类行通过系统习惯的侧滑操作提供删除。
- 没有账目的分类可以简单删除。
- 有账目的分类必须展示具体明细，让用户选择转到其他二级分类，或者连同账目一起删除。
- 去掉用户不理解的右上角删除图标。

## 视觉观察

- 截图中分类管理首页右上角同时存在垃圾桶和新增按钮，但列表行上只有编辑笔和进入子分类的箭头。
- 垃圾桶没有文字标签，既不指向某一个分类，也没有批量选中状态，用户无法预测它会删什么。
- 列表的主要任务是浏览和管理单个分类，删除应该与分类行绑定，而不是放在页面全局导航区。

## 代码事实

1. `CategoryManagementView` 的删除按钮仅在 `!category.isDefault && !category.isSystem` 时出现。所有种子分类都是 `isDefault = true`，因此绝大多数分类天然不能删除。
2. `isSystem` 已经是“不允许编辑/删除”的专用字段；`isDefault` 的原始语义是“系统预设来源”。当前 UI 把两者重复当成权限。
3. 右上角垃圾桶调用 `cleanupImportedCategories()`，它不是删除当前分类，而是扫描所有 `isDefault == false` 的分类，删除未被交易使用的项。
4. 该“清理导入分类”实际不检查 `importBatchId`，所以会把用户手动创建的空分类也当成导入分类删除，名称与行为不一致。
5. 当前工作区未提交改动已加入“显示账目、转移或一起删除”的弹层，但转移候选仅按收支类型过滤，没有限定 `isSubCategory`，会让交易被转到一级分类，与“记账必须使用二级分类”的业务不变量冲突。
6. 删除一级分类时，当前修补会把其所有子分类账目打平后一次性转到同一个目标，会丢失原有语义。
7. `deleteCategory` 会物理删除分类和账目，而 Holo 数据治理已有 `deletedAt + deletedBatchId` 的 30 天回收站契约。
8. 预设分类的补种逻辑会根据现存名称补齐缺失分类。物理删除预设分类会让它在后续启动时重新出现；软删除墓碑仍在时，当前补种查询会把它视为已存在，可防止复活。
9. 分类除交易外还被 `Budget.categoryId` 和 `SpendingProject.categoryId` 引用。当前修补会静默物理删除预算，但不处理固定支出引用，会留下悬空 `categoryId`。
10. 现有智能分类学习主要以“一级分类名 + 二级分类名”保存目标。删除或改名分类不会自动清理/改指这些规则，后续识别可持续命中无效目标。
11. Core Data 中 `Transaction.category` 对分类删除使用 nullify，如果仓库逻辑漏处理，交易会被保留但变成无分类数据。

## 需要保持的业务不变量

- 交易只能挂在二级分类。
- 交易和目标分类收支类型必须一致。
- 分类删除、交易转移/软删除、预算与固定支出改指、学习规则治理必须在一次原子保存中完成。
- 预设分类可删，系统内部分类不可删。
- 任何会删除账目或未来自动记账配置的操作都不得只用“删除分类”一个模糊按钮承载。

## 相关资源

- `Holo/Holo APP/Holo/Holo/Views/CategoryManagementView.swift`
- `Holo/Holo APP/Holo/Holo/Models/FinanceRepository+Categories.swift`
- `Holo/Holo APP/Holo/Holo/Models/Category+CoreDataProperties.swift`
- `Holo/Holo APP/Holo/Holo/Models/CoreDataStack+FinanceEntities.swift`
- `Holo/Holo APP/Holo/Holo/Models/CategoryLearningStore.swift`
- `Holo/Holo APP/Holo/Holo/Services/AI/CategoryLearnedMapping.swift`
- `Holo/Holo APP/Holo/Holo/Services/RecycleBinService.swift`
- `Holo/Holo APP/Holo/Holo/Services/RecycleBinRestoreEngine.swift`


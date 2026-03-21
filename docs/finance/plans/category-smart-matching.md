# 导入账单科目智能匹配功能

## Context

用户导入账单时，CSV 中的科目名可能与预设科目名有细微差异（如「早饭」vs「早餐」），导致系统创建重复的问号图标分类。

**用户需求**：
1. ✅ 支持同义词匹配（如「早饭」→「早餐」）
2. ✅ 匹配结果预览，用户二次确认
3. ✅ 用户不满意时可自定义科目

## 实现方案

### 1. 新增数据模型

**文件**: `ImportExportModels.swift`

```swift
enum CategoryMatchType {
    case exact       // 精确匹配
    case fuzzy       // 模糊匹配
    case synonym     // 同义词匹配
    case unmatched   // 无匹配
}

struct CategoryMatchResult {
    let originalPrimary: String      // 原始一级分类
    let originalSub: String          // 原始二级分类
    let matchType: CategoryMatchType
    var matchedCategory: Category?   // 匹配结果
    var candidates: [Category]       // 候选列表
    var confidence: Double           // 置信度
    var isManuallyModified: Bool     // 用户是否手动修改
}
```

### 2. 同义词映射

**新文件**: `Services/CategorySynonymMapping.swift`

配置常用同义词，如：
- 早餐 ← 早饭、早点
- 打车 ← 出租车、滴滴、网约车
- 地铁 ← 轨道交通、捷运

### 3. 智能匹配服务

**新文件**: `Services/CategoryMatcherService.swift`

匹配策略（按优先级）：
1. **精确匹配**: 名称完全相同（忽略大小写/空白）
2. **同义词匹配**: 查同义词映射表
3. **模糊匹配**: Levenshtein 编辑距离 + 公共前缀加成

### 4. UI 改造

**文件**: `ImportPreviewSheet.swift`

新增「分类匹配预览」Section：
- 显示匹配统计（精确/智能/待确认）
- 匹配列表，点击可调整
- 无匹配项高亮提示

### 5. 导入逻辑修改

**文件**: `FinanceRepository.swift`

修改 `batchImportTransactions`:
- 接收预匹配结果参数
- 使用匹配到的分类
- 新建分类时智能选择图标/颜色

## 关键文件

| 文件 | 改动 |
|------|------|
| `Models/ImportExportModels.swift` | 新增匹配结果模型 |
| `Services/CategorySynonymMapping.swift` | 新建同义词配置 |
| `Services/CategoryMatcherService.swift` | 新建匹配服务 |
| `Views/Settings/ImportPreviewSheet.swift` | 添加匹配预览 UI |
| `Models/FinanceRepository.swift` | 修改导入方法 |

## 验证方式

1. 导入测试 CSV，包含：
   - 与预设完全相同的科目名
   - 同义词（如「早饭」应匹配「早餐」）
   - 相似但不完全相同的科目名
   - 完全无匹配的科目名
2. 检查匹配预览界面显示是否正确
3. 手动调整匹配结果并导入
4. 验证导入后分类图标/颜色正确

## 预估工作量

- 基础设施（数据模型 + 同义词配置）: 0.5 天
- 匹配算法服务: 1 天
- UI 改造: 1 天
- 导入逻辑修改 + 联调: 0.5 天

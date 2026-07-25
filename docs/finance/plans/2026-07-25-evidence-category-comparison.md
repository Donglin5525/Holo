# 财务数据依据页：合计切换 + 科目对比视图

> 日期：2026-07-25 ｜ 状态：已实施

## 背景

「财务数据依据」页（`FinanceEvidenceReviewView`）原有两个体验问题：

1. 点「本期合计/对比期合计」直接跳统计页，下方"本期明细+对比期明细"两条长列表上下堆叠，无法灵活只看某一期。
2. 两个总金额并排摆放，但看不出钱差在哪个科目上，无法真正对比两个月差异。

## 方案

### 1. 合计卡片改为期次选择器
- 点击卡片切换 `selectedPeriod`，选中态：holoPrimary 边框 + 浅底色 + 标题/笔数着色
- 下方只保留一个明细列表，数据源与标题（含日期区间）随选中期次切换
- 原跳统计页功能收拢为汇总卡右上角「统计分析 ›」小入口，时间段跟随选中期次

### 2. 明细 / 科目对比 分段切换
- 复用 `CategoryTabView.typeSwitcher` 样式；仅当 deep link 带 baseline 时显示

### 3. 科目对比视图
- `Models/CategoryComparison.swift`：纯 Swift 聚合（`CategoryComparisonBuilder.build`），输入为轻量 `CategoryComparisonInput`（categoryID + amount）+ 分类信息字典，不依赖 Core Data，可 standalone 测试
- 按一级科目对齐两期金额（二级归入父级），取两期并集，按 |差额| 降序；未分类归入固定 ID 组
- `Views/Finance/CategoryComparisonListView.swift`：总差额摘要行（多支出红/少支出绿/持平灰，复用 MonthlySummaryCard 语义）、三列（本期/对比期/差额）+ 列头、一级行内展开二级、仅一期有数据显示「新增」胶囊；标题行右侧排序 Menu：按差额（默认）/ 金额从高到低 / 金额从低到高，一级与二级同步重排（`CategoryComparisonBuilder.sorted`）
- 数据源为页面内存中的两期交易，本地聚合，零新增 Core Data 查询，天然尊重关键词过滤

## 涉及文件

| 操作 | 文件 |
|------|------|
| 新增 | `Holo/Models/CategoryComparison.swift` |
| 新增 | `Holo/Views/Finance/CategoryComparisonListView.swift` |
| 新增 | `HoloTests/Models/CategoryComparisonBuilderTests.swift`（standalone 桥接模式，35 断言） |
| 修改 | `Holo/Views/Finance/FinanceEvidenceReviewView.swift` |
| 修改 | `Holo.xcodeproj/project.pbxproj`（测试文件引用） |

## 验证

- standalone 测试：`swiftc -parse-as-library Holo/Models/CategoryComparison.swift HoloTests/Models/CategoryComparisonBuilderTests.swift -o /tmp/category_comparison_test && /tmp/category_comparison_test` → 35 assertions passed
- `xcodebuild build` App target 编译通过
- 注意：HoloTests target 在 main 上存在既有编译问题（部分旧 standalone 测试 `@main` 未走 HOLO_XCTEST_BRIDGE 桥接 + Evals 测试引用不到类型），与本功能无关

# 财务分类图标迁移至 SF Symbols 方案

## Context

当前财务模块有 97 个自定义 SVG 图标（来自 Figma 设计），存储在 `Assets.xcassets/CategoryIcons/`。图标风格不统一、维护成本高。迁移到 SF Symbols 可以：
- 消除 97 个自定义 SVG 资源的维护负担
- 获得与 iOS 系统一致的视觉语言
- 自动支持多平台、RTL、无障碍

**好消息**：渲染函数 `transactionCategoryIcon()` 已内置 SF Symbol 支持，只需改数据即可切换。

**用户决策**：
- 验证方式：**先看预览再动手**（Phase 1 只建预览，确认满意后再执行 Phase 2-4）
- 小尺寸优化：**必须调优**，12pt 排行榜图标也需清晰可辨

---

## 数据安全分析

**`icon` 字段只用于展示，不参与查询/排序/关联。**

```
Transaction → category.id (UUID 引用) → Category.icon (仅展示)
```

- 交易记录通过 UUID 关联分类，不依赖 icon 名称
- 迁移只改 Category.icon 的字符串值，不动数据库结构
- 一次性迁移函数 + UserDefaults 标记确保安全执行
- 迁移失败时不设标记，下次启动自动重试

---

## 实施步骤

### Phase 1: 建立映射 + 质量预览（暂停等确认）

**1.1 创建 SF Symbol 映射字典**

在 `Category+CoreDataProperties.swift` 中添加 `legacyIconMapping`，覆盖全部图标：

#### 支出类别

**餐饮 → `fork.knife`**

| 子类别 | 当前图标 | SF Symbol | 说明 |
|--------|----------|-----------|------|
| 早餐 | icon_breakfast | `sunrise.fill` | 早晨 |
| 午餐 | icon_lunch | `sun.max.fill` | 正午 |
| 晚餐 | icon_dinner | `moon.stars.fill` | 傍晚 |
| 夜宵 | icon_late_snack | `moonphase.waning.crescent` | 深夜 |
| 零食 | icon_snack | `popcorn.fill` | 零食 |
| 咖啡 | icon_coffee | `cup.and.saucer.fill` | 咖啡杯 |
| 外卖 | icon_takeout | `bag.fill` | 外卖袋 |
| 饮品 | icon_beverage | `wineglass.fill` | 饮品杯 |
| 水果 | icon_fruit | `apple.meditation` | 苹果 |
| 酒水 | icon_alcohol | `wineglass` | 酒杯 |
| 超市 | icon_supermarket | `cart.fill` | 购物车 |

**交通 → `car.fill`**

| 子类别 | 当前图标 | SF Symbol | 说明 |
|--------|----------|-----------|------|
| 地铁 | icon_metro | `train.side.front.car` | 地铁 |
| 打车 | icon_taxi | `car.side.fill` | 出租车 |
| 公交 | icon_bus | `bus.fill` | 公交 |
| 单车 | icon_bike_share | `bicycle` | 自行车 |
| 加油 | icon_fuel | `fuelpump.fill` | 加油 |
| 停车 | icon_parking | `parkingsign.circle.fill` | 停车 |
| 火车 | icon_train | `train.side.rear.car` | 火车 |
| 机票 | icon_flight | `airplane.departure` | 飞机 |
| 旅行 | icon_travel | `figure.walk` | 步行旅行 |
| 过路费 | icon_toll | `building.columns.fill` | 收费站 |

**购物 → `bag.fill`**

| 子类别 | 当前图标 | SF Symbol | 说明 |
|--------|----------|-----------|------|
| 服饰 | icon_clothes | `hanger` | 衣架 |
| 数码 | icon_digital | `desktopcomputer` | 电子 |
| 日用 | icon_groceries | `basket.fill` | 日用 |
| 美妆 | icon_beauty | `lipstick` | 化妆品 |
| 家具 | icon_furniture | `couch.fill` | 家具 |
| 书籍 | icon_book | `book.fill` | 书 |
| 运动 | icon_sport | `sportscourt.fill` | 运动 |
| 礼物 | icon_present | `gift.fill` | 礼物 |

**娱乐 → `gamecontroller.fill`**

| 子类别 | 当前图标 | SF Symbol | 说明 |
|--------|----------|-----------|------|
| 电影 | icon_cinema | `film.fill` | 电影 |
| 游戏 | icon_gaming | `gamecontroller.fill` | 游戏 |
| 视频 | icon_video | `play.tv.fill` | 视频 |
| 音乐 | icon_music | `music.note.list` | 音乐 |
| KTV | icon_ktv | `mic.fill` | 麦克风 |
| 旅游 | icon_trip | `airplane` | 旅行 |
| 健身 | icon_fitness | `figure.run` | 跑步 |

**居住 → `house.fill`**

| 子类别 | 当前图标 | SF Symbol | 说明 |
|--------|----------|-----------|------|
| 房租 | icon_rent | `key.fill` | 钥匙 |
| 房贷 | icon_mortgage | `banknote.fill` | 银行票据 |
| 水费 | icon_water | `drop.fill` | 水滴 |
| 电费 | icon_electricity | `bolt.fill` | 闪电 |
| 燃气 | icon_gas | `flame.fill` | 火焰 |
| 物业 | icon_property | `building.2.fill` | 建筑群 |
| 网费 | icon_internet | `wifi` | Wi-Fi |
| 家电 | icon_appliance | `tv.fill` | 电视 |
| 装修 | icon_renovation | `paintbrush.fill` | 油漆刷 |

**医疗 → `heart.text.square.fill`**

| 子类别 | 当前图标 | SF Symbol | 说明 |
|--------|----------|-----------|------|
| 就医 | icon_medical | `stethoscope` | 听诊器 |
| 药品 | icon_medicine | `pill.fill` | 药丸 |
| 体检 | icon_checkup | `heart.text.square.fill` | 健康检查 |
| 健身房 | icon_gym | `dumbbell.fill` | 哑铃 |
| 保健品 | icon_supplement | `leaf.fill` | 天然 |
| 牙科 | icon_dental | `heart.circle.fill` | 健康 |
| 医疗用品 | icon_medical_supply | `cross.case.fill` | 医疗箱 |

**教育 → `book.closed.fill`**

| 子类别 | 当前图标 | SF Symbol | 说明 |
|--------|----------|-----------|------|
| 课程 | icon_course | `book.closed.fill` | 教材 |
| 教材 | icon_textbook | `text.book.closed.fill` | 教科书 |
| 考试 | icon_exam | `checkmark.rectangle.fill` | 考试 |
| 文具 | icon_stationery | `pencil.line` | 铅笔 |
| 订阅 | icon_subscription | `arrow.trianglehead.clockwise` | 订阅 |

**社交 → `person.2.fill`**

| 子类别 | 当前图标 | SF Symbol | 说明 |
|--------|----------|-----------|------|
| 红包礼金 | icon_cash_gift | `yensign.circle.fill` | 人民币符号 |
| 请客 | icon_treat | `wineglass.fill` | 招待 |
| 送礼 | icon_gifting | `gift.fill` | 赠礼 |
| 探望 | icon_visit | `figure.walk.arrival` | 拜访 |
| 其他 | icon_social_other | `ellipsis.circle.fill` | 其他 |

**其他支出 → `square.grid.2x2.fill`**

| 子类别 | 当前图标 | SF Symbol | 说明 |
|--------|----------|-----------|------|
| 社交 | icon_social | `person.2.fill` | 人群 |
| 宠物 | icon_pet | `pawprint.fill` | 爪印 |
| 理发 | icon_barber | `scissors` | 剪刀 |
| 洗衣 | icon_laundry | `washer.fill` | 洗衣机 |
| 话费 | icon_phone_bill | `phone.fill` | 电话 |
| 烟酒 | icon_tobacco_alcohol | `smoke.fill` | 烟 |
| 维修 | icon_repair | `wrench.fill` | 扳手 |
| 保险 | icon_insurance | `shield.checkered` | 保险 |
| 还款 | icon_repayment | `arrow.uturn.backward.circle.fill` | 还款 |
| 转账 | icon_transfer_out | `arrow.right.circle.fill` | 转出 |
| 捐赠 | icon_donation | `heart.fill` | 慈善 |
| 其他 | icon_other_exp | `questionmark.folder.fill` | 其他 |

#### 收入类别

**投资理财 → `chart.line.uptrend.xyaxis`**

| 子类别 | 当前图标 | SF Symbol | 说明 |
|--------|----------|-----------|------|
| 利息 | icon_interest | `percent` | 百分比 |
| 股票 | icon_stock | `chart.line.uptrend.xyaxis` | 股票图表 |
| 房租收入 | icon_rent_income | `building.columns.fill` | 租金 |
| 其他投资 | icon_invest_other | `chart.pie.fill` | 投资组合 |

**工资收入 → `banknote.fill`**

| 子类别 | 当前图标 | SF Symbol | 说明 |
|--------|----------|-----------|------|
| 工资 | icon_salary | `banknote.fill` | 货币 |
| 奖金 | icon_bonus | `star.fill` | 奖励 |
| 兼职 | icon_parttime | `briefcase.fill` | 工作 |
| 报销 | icon_reimburse | `arrow.uturn.backward.circle.fill` | 报销 |
| 退款 | icon_refund | `arrow.counterclockwise.circle.fill` | 退款 |

**人情来往 → `gift.fill`**

| 子类别 | 当前图标 | SF Symbol | 说明 |
|--------|----------|-----------|------|
| 红包 | icon_red_packet | `yensign.circle.fill` | 红包 |
| 礼物 | icon_gift | `gift.fill` | 礼物 |
| 中奖 | icon_winning | `trophy.fill` | 奖杯 |
| 转入 | icon_transfer_in | `arrow.left.circle.fill` | 转入 |

**其他收入 → `plus.circle.fill`**

| 子类别 | 当前图标 | SF Symbol | 说明 |
|--------|----------|-----------|------|
| 借入 | icon_loan_in | `arrow.down.circle.fill` | 流入 |
| 还款收入 | icon_repay_in | `arrow.uturn.forward.circle.fill` | 归还 |
| 退货 | icon_return | `shippingbox.fill` | 包裹 |
| 公积金 | icon_housing_fund | `building.columns.fill` | 住房基金 |
| 出闲置 | icon_secondhand | `arrow.3.trianglepath` | 循环 |
| 其他 | icon_other_inc | `questionmark.folder.fill` | 其他 |

#### 父类别/选择器额外图标

| 当前图标 | SF Symbol | 说明 |
|----------|-----------|------|
| icon_dining | `fork.knife` | 餐饮 |
| icon_transport | `car.fill` | 交通 |
| icon_shopping | `bag.fill` | 购物 |
| icon_entertainment | `music.note.list` | 娱乐 |
| icon_housing | `house.fill` | 居住 |
| icon_health | `heart.text.square.fill` | 医疗 |
| icon_education | `book.closed.fill` | 教育 |
| icon_investment | `chart.line.uptrend.xyaxis` | 投资 |
| icon_other_income | `plus.circle.fill` | 其他收入 |
| icon_other_expense | `questionmark.folder.fill` | 其他支出 |
| icon_communication | `phone.fill` | 通讯 |

**1.2 构建 SwiftUI 预览对比视图**

创建临时文件 `IconMigrationPreview.swift`（仅 Debug），功能：
- 网格并排显示：分类名称 | 旧图标 | 新 SF Symbol
- **三种尺寸展示**：12pt（排行榜）、22pt（列表）、44pt（选择器），验证小尺寸可辨性
- 分组按类别展示，方便对比同组图标风格一致性
- 不满意的映射标红，便于后续调整

**Phase 1 交付后暂停，等你模拟器确认再继续。**

### Phase 1.5: 小尺寸调优

根据预览结果，对 12pt 下辨识度不足的 SF Symbol 进行调优：
- 优先使用 `.fill` 变体（笔画更粗，小尺寸更清晰）
- 考虑使用 `.circle.fill` 包裹变体（圆形背景增强辨识度）
- 必要时对部分映射替换为更简洁的符号

### Phase 2: 数据层迁移（等 Phase 1 确认后执行）

**2.1 更新种子数据**

文件：`Models/Category+CoreDataProperties.swift`
- 将 `expenseHierarchy` 和 `incomeHierarchy` 中所有 `icon: "icon_xxx"` 替换为 SF Symbol 名

**2.2 添加一次性迁移函数**

在 `Category` 扩展中添加 `migrateLegacyIcons(in:)`：
- 用 `UserDefaults` 标记 `"hasMigratedToSFSymbols_v1"` 确保只执行一次
- 遍历所有 Category，将旧的 `icon_` 名称重映射为 SF Symbol
- 迁移完成后 save context，再设置 flag

**2.3 集成迁移调用**

在 `seedDefaultCategories()` 末尾调用迁移函数

### Phase 3: UI 层更新

**3.1 更新 `Category+Icon.swift`**

简化渲染函数：
- 移除 `UIImage(named: "CategoryIcons/...")` 查找逻辑
- 直接使用 `Image(systemName:)` + `.font(.system(size: size * 0.6, weight: .medium))`
- 保留 `icon_` 前缀的 `tag.fill` 回退（兼容用户自定义分类）

**3.2 更新 `IconPickerGrid.swift`**

- `presetCategoryIcons` 数组替换为 SF Symbol 名称
- 单元格渲染从 `Image(iconName).renderingMode(.template)` 改为 `Image(systemName: iconName).font(.system(size: 22, weight: .medium))`

**3.3 更新 `QuickTemplateView.swift`**

同步更新 `quickTemplateCategoryIcon()` 函数（第 121-149 行），或重构为调用 `transactionCategoryIcon()` 消除重复

### Phase 4: 清理

**4.1 删除旧资源**

- 删除 `Assets.xcassets/CategoryIcons/` 全部 97 个 imageset
- 搜索确认无其他引用

**4.2 删除预览文件**

- 移除 `IconMigrationPreview.swift`

**4.3 全链路验证**

- 新安装测试（无旧数据）
- 升级安装测试（有旧 `icon_` 数据）
- 6 个视图位置全部验证：CategoryPicker、CategoryManagementView、AddTransactionSheet、FinanceView、TopCategoryCard、CategoryLegendRow

---

## 关键文件

| 文件 | 改动 |
|------|------|
| `Models/Category+CoreDataProperties.swift` | 更新种子数据 + 添加迁移映射和函数 |
| `Models/Category+Icon.swift` | 简化渲染函数 |
| `Components/IconPickerGrid.swift` | 替换图标数组 + 渲染逻辑 |
| `Components/QuickTemplateView.swift` | 同步渲染逻辑 |
| `Assets.xcassets/CategoryIcons/` | 全部删除 |
| `IconMigrationPreview.swift`（临时） | Debug 预览对比 |

## 风险

| 风险 | 级别 | 缓解 |
|------|------|------|
| 部分 SF Symbol 仅 iOS 15+ 可用 | 高 | 在 SF Symbols app 中逐一验证 iOS 版本 |
| 视觉密度不一致 | 中 | 预览对比视图发现并调整 |
| 中文特色概念无精确匹配（KTV/夜宵/红包） | 中 | 使用语义近似符号，中国用户普遍接受 |
| 用户自定义分类使用旧 `icon_` 名称 | 低 | 渲染函数有 `tag.fill` 回退，用户可重选 |

# 健康模块开发计划

> **状态**: 待开发
> **日期**: 2026-03-24
> **预估工时**: 2-3 天

---

## 📋 开发阶段

### 阶段一：项目配置（30分钟）

#### 1.1 Info.plist 权限配置
```xml
<key>NSHealthShareUsageDescription</key>
<string>Holo 需要读取您的健康数据来展示步数、睡眠和站立时长</string>
```

#### 1.2 Xcode Entitlements 配置
- [ ] Signing & Capabilities → + Capability → HealthKit
- [ ] 勾选 HealthKit（只读取，不写入）
- [ ] 勾选需要读取的数据类型：
  - `HKQuantityTypeIdentifierStepCount` (步数)
  - `HKCategoryTypeIdentifierSleepAnalysis` (睡眠)
  - `HKQuantityTypeIdentifierAppleStandTime` (站立)

---

### 阶段二：数据层（2小时）

#### 2.1 HealthRepository.swift
**路径**: `Models/HealthRepository.swift`

**职责**:
- HealthKit 权限请求
- 读取当日健康数据
- 读取 7 天历史数据
- 模拟数据支持（用于模拟器测试）

**核心方法**:
```swift
@MainActor
class HealthRepository: ObservableObject {
    static let shared = HealthRepository()

    // 权限状态
    @Published var isAuthorized: Bool = false
    @Published var hasRequestedPermission: Bool = false

    // 今日数据
    @Published var todaySteps: Double = 0
    @Published var todaySleep: Double = 0
    @Published var todayStandHours: Double = 0

    // 请求权限
    func requestAuthorization() async throws

    // 读取今日数据
    func fetchTodayData() async

    // 读取 7 天历史数据
    func fetchWeeklyData(for type: HealthMetricType) async -> [DailyHealthData]

    // 检查权限状态
    func checkAuthorizationStatus() async
}
```

**注意**:
- 模拟器无法读取 HealthKit，需提供 `useMockData` 开关
- 睡眠数据需要特殊处理（累计所有睡眠时间段）

---

### 阶段三：UI 组件（4小时）

#### 3.1 HealthRingView.swift
**路径**: `Views/Health/Components/HealthRingView.swift`

**设计规范**:
| 属性 | 值 |
|------|-----|
| 圆环大小 | 80x80 |
| 圆环粗细 | 12pt |
| 背景环颜色 | holoDivider |
| 进度颜色 | 按指标类型 |
| 动画 | easeInOut 0.5s |

**参数**:
```swift
struct HealthRingView: View {
    let progress: Double  // 0-100
    let color: Color
    let icon: String
    let label: String
}
```

#### 3.2 HealthMetricCard.swift
**路径**: `Views/Health/Components/HealthMetricCard.swift`

**布局**:
```
┌─────────────────────────────────┐
│  [图标]  指标名称                │
│          当前值 / 目标值         │
│          ████████░░░░ 72%       │
└─────────────────────────────────┘
```

**参数**:
```swift
struct HealthMetricCard: View {
    let type: HealthMetricType
    let value: Double
    let goal: Double
    let onTap: () -> Void
}
```

#### 3.3 HealthTrendChart.swift
**路径**: `Views/Health/Components/HealthTrendChart.swift`

**参考**: `HabitBarChartView.swift`

**功能**:
- 7 天柱状图
- 显示日期标签
- 空数据占位

---

### 阶段四：主视图（2小时）

#### 4.1 HealthView.swift
**路径**: `Views/Health/HealthView.swift`

**布局结构**:
```
VStack {
    // 日期标题
    headerView

    // 三个圆环
    HStack { ringViews }

    // 指标卡片列表
    ScrollView {
        VStack {
            ForEach(metrics) { card }
        }
    }
}
```

**状态管理**:
- 权限未授权 → 显示 `HealthPermissionView`
- 已授权 → 显示数据

#### 4.2 HealthPermissionView.swift
**路径**: `Views/Health/Components/HealthPermissionView.swift`

**内容**:
- 说明需要读取的健康数据
- 「授权」按钮
- 「稍后再说」按钮

---

### 阶段五：详情页（1.5小时）

#### 5.1 HealthDetailView.swift
**路径**: `Views/Health/HealthDetailView.swift`

**内容**:
- 大圆环显示当前进度
- 7 天趋势柱状图
- 统计摘要（7 天平均、最高值、达标天数）

---

## 📁 文件结构

```
Models/
├── HealthMetricType.swift      ✅ 已有
└── HealthRepository.swift      ❌ 待创建

Views/Health/
├── HealthView.swift            ❌ 待创建
├── HealthDetailView.swift      ❌ 待创建
└── Components/
    ├── HealthRingView.swift         ❌ 待创建
    ├── HealthMetricCard.swift       ❌ 待创建
    ├── HealthTrendChart.swift       ❌ 待创建
    └── HealthPermissionView.swift   ❌ 待创建
```

---

## ⚠️ 注意事项

### 模拟器限制
模拟器无法访问 HealthKit，开发时需要：
1. 在 `HealthRepository` 中添加 `useMockData` 开关
2. 提供模拟数据用于 UI 开发和预览
3. 真机测试时关闭模拟数据

### 睡眠数据处理
睡眠数据的特殊处理：
- `HKCategoryTypeIdentifierSleepAnalysis` 返回多个时间段
- 需要累计当日所有 `InBed` 和 `Asleep` 状态的时长
- 睡眠日期归属：按「起床日期」归类（凌晨 0-6 点的睡眠归到前一天）

### 权限处理
- 用户可能拒绝部分权限，需单独处理每个指标
- 用户可能后续在系统设置中修改权限，需在 `viewWillAppear` 检查状态
- 未授权的指标显示占位状态

---

## ✅ 验收标准

- [ ] 首次进入显示权限引导页
- [ ] 授权后显示今日三指标圆环
- [ ] 圆环进度与 Apple Health 数据一致
- [ ] 点击卡片进入详情页
- [ ] 详情页显示 7 天趋势图
- [ ] 未授权指标显示占位状态
- [ ] 模拟器可使用模拟数据
- [ ] 编译无警告
- [ ] 无 force unwrap 和 print

---

## 🚀 开发顺序建议

1. **配置先行** → Info.plist + Entitlements
2. **数据层** → HealthRepository（先实现模拟数据）
3. **组件开发** → HealthRingView → HealthMetricCard → HealthTrendChart
4. **主视图** → HealthView + HealthPermissionView
5. **详情页** → HealthDetailView
6. **真机测试** → 验证真实 HealthKit 数据

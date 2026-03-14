# HOLO iOS 项目开发规范

## 全局中文化要求

Holo 是面向中文用户的 APP。**所有 UI 文本、按钮标签、占位符、提示语、日期格式必须使用简体中文**。禁止英文文案出现在界面中（品牌名 "Holo" 除外）。日期使用 `Locale(identifier: "zh_CN")`，货币使用人民币 `CNY`。

## 项目创建

### 技术栈选择
- **框架**: SwiftUI (首选)
- **语言**: Swift 5.0+
- **最低版本**: iOS 17.0
- **架构**: MVVM

### 创建步骤
1. Xcode → File → New → Project
2. 选择 **iOS → App**
3. **关键配置**:
   - Product Name: `Holo`
   - Interface: **SwiftUI** (不要选 Storyboard)
   - Language: **Swift**
   - Testing System: None
   - Storage: None

### 项目结构
```
Holo/
├── HoloApp.swift          # 应用入口
├── ContentView.swift      # 主导航 (TabView)
├── Views/
│   ├── TodayView.swift    # 今天页面
│   ├── HOLOView.swift     # 对话页面
│   ├── FinanceView.swift  # 财务页面
│   ├── HealthView.swift   # 健康页面
│   └── ProfileView.swift  # 个人中心
├── Components/            # 可复用组件
├── Models/                # 数据模型
├── Utils/                 # 工具函数
└── Assets.xcassets        # 资源文件
```

## 代码规范

### SwiftUI 组件规范

**文件命名**:
- 视图文件：`XXXView.swift` (如 `TodayView.swift`)
- 组件文件：`XXXComponent.swift` 或直接描述性命名
- 模型文件：`XXX.swift` 或 `XXXModel.swift`

**基本结构**:
```swift
import SwiftUI

/// 页面/组件的中文描述
struct XXXView: View {
    // MARK: - Properties
    
    @State private var variable: Type = defaultValue
    
    // MARK: - Body
    
    var body: some View {
        // 视图代码
    }
}

// MARK: - Preview

#Preview {
    XXXView()
}
```

**设计规范**:
- 使用 `@State` 管理本地状态
- 使用 `@Binding` 传递双向绑定
- 使用 `@ObservedObject` 或 `@StateObject` 管理 ViewModel
- 所有视图提供 `#Preview`

### 设计系统

**颜色**:
```swift
// 主色调
Color.orange  // #FF6B35 - HOLO 主色

// 背景色
Color(red: 0.97, green: 0.97, blue: 0.98)  // #F7F7F8 - 浅灰背景
Color.white   // 卡片背景
```

**圆角**:
- 大卡片：`cornerRadius(20)`
- 小卡片：`cornerRadius(16)`
- 按钮/标签：`cornerRadius(12)` 或 `cornerRadius(8)`

**阴影**:
```swift
.shadow(color: Color.black.opacity(0.06), radius: 8, y: 2)
.shadow(color: Color.black.opacity(0.08), radius: 12, y: 4)
```

**字体**:
```swift
// 大标题
.font(.system(size: 28, weight: .bold))

// 页面标题
.font(.system(size: 20, weight: .bold))

// 正文
.font(.system(size: 16, weight: .medium))
.font(.system(size: 15, weight: .regular))

// 辅助文字
.font(.system(size: 13, weight: .regular))
```

## 开发流程

### 1. 创建新页面
1. 在 `Views/` 目录创建 `XXXView.swift`
2. 遵循基本结构模板
3. 添加 `#Preview`
4. 在 `ContentView.swift` 中注册 Tab

### 2. 运行调试
1. 选择模拟器 (iPhone 15/17 Pro)
2. 按 `⌘ + R` 运行
3. 按 `⌥ + ⌘ + P` 查看实时预览

### 3. 代码检查
- 确保所有视图有 `#Preview`
- 确保遵循命名规范
- 确保使用设计系统颜色/字体

## 常见错误避免

❌ **不要使用 UIKit** (除非特殊需求)
- 不要创建 `AppDelegate.swift`
- 不要创建 `SceneDelegate.swift`
- 不要使用 `Storyboard`

❌ **不要手动创建 project.pbxproj**
- 始终使用 Xcode 创建项目
- 文件通过 Xcode 添加 (File → New → File)

❌ **不要混合 SwiftUI 和 UIKit**
- 新手项目保持纯 SwiftUI
- 避免使用 `UIViewRepresentable`

## iOS 安全区与布局规范

### 安全区处理（灵动岛/刘海）
```swift
// ❌ 错误：顶部内容会被灵动岛遮挡
.padding(.top, 0)

// ✅ 正确：顶部内容留足间距
.padding(.top, 8)  // 最小 8pt，推荐 10~12pt
```

### 容器高度精确计算
当子视图有固定高度时，容器高度必须精确计算，避免内容被裁切：
```swift
// 假设子组件：标题行 16pt + 间距 6pt + 格子 56pt + 底部 8pt
.frame(height: 90)  // 16 + 6 + 56 + 8 + 4(buffer) = 90

// ❌ 错误：估算值导致裁切
.frame(height: 70)  // 内容会被遮挡
```

### Sheet 弹窗 Detent 选择
```swift
// .medium ≈ 屏幕 50%，可能不够展示完整内容

// ❌ 错误：内容显示不完整
.presentationDetents([.medium, .large])

// ✅ 正确：根据内容高度自定义
.presentationDetents([.height(480), .large])  // 480pt 足够放下月历
```

### 互斥视图处理
功能相似的视图（如周视图 vs 月历视图）应该互斥显示：
```swift
// ✅ 正确：展开月历时隐藏周视图
WeekView()
    .opacity(1 - revealProgress)           // 渐隐
    .frame(height: 90 * (1 - revealProgress))  // 高度收缩
    .clipped()
```

### 交互可发现性
隐藏的交互（滑动、长按等）需要视觉提示：
```swift
// ✅ 正确：上滑提示
HStack {
    Image(systemName: "chevron.up")
    Text("上滑查看更多")
}
.foregroundColor(.secondary.opacity(0.5))
```

### 信息去重原则
同一信息只展示一次，保留最醒目的：
```swift
// ❌ 错误：两个时间显示
VStack {
    Text("2026年3月14日 周五")  // 灰色小字
    Text("今日账本")            // 加粗标题
}

// ✅ 正确：只保留标题
Text("今日账本")
    .font(.holoTitle)
```

## 快速开始模板

创建新页面时，使用以下模板：

```swift
import SwiftUI

/// 页面描述
struct XXXView: View {
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 内容
                }
            }
            .navigationTitle("页面标题")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

#Preview {
    XXXView()
}
```

## 更新日志

- 2026-03-14: 新增「iOS 安全区与布局规范」— 灵动岛避让、容器高度计算、Sheet detent、互斥视图、交互可发现性、信息去重
- 2026-03-01: 初始版本，确定使用 SwiftUI

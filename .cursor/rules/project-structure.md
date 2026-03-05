# HOLO 项目结构规范

## 目录结构

```
Holo/
├── .cursor/
│   └── rules/               # Cursor 规则文件
├── Holo/
│   ├── HoloApp.swift        # 应用入口 @main
│   ├── ContentView.swift    # 主 Tab 导航
│   ├── Views/               # 页面视图
│   │   ├── TodayView.swift
│   │   ├── HOLOView.swift
│   │   ├── FinanceView.swift
│   │   ├── HealthView.swift
│   │   └── ProfileView.swift
│   ├── Components/          # 可复用组件
│   │   ├── HoloCard.swift
│   │   ├── TaskRow.swift
│   │   └── QuickActionButton.swift
│   ├── Models/              # 数据模型
│   │   ├── Task.swift
│   │   ├── Transaction.swift
│   │   └── HealthMetric.swift
│   ├── ViewModels/          # 视图模型 (MVVM)
│   │   └── TaskViewModel.swift
│   ├── Utils/               # 工具函数
│   │   ├── Constants.swift
│   │   └── Extensions.swift
│   └── Assets.xcassets      # 资源文件
│       ├── AppIcon.appiconset
│       ├── AccentColor.colorset
│       └── Contents.json
├── Holo.xcodeproj
└── README.md
```

## 文件模板

### 视图文件 (Views/XXXView.swift)

```swift
import SwiftUI

/// 页面中文描述
struct XXXView: View {
    // MARK: - Properties
    
    @State private var variable: Type = defaultValue
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 内容
                }
            }
            .navigationTitle("标题")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - Preview

#Preview {
    XXXView()
}
```

### 组件文件 (Components/XXX.swift)

```swift
import SwiftUI

/// 组件中文描述
struct XXX: View {
    // MARK: - Properties
    
    let data: DataType
    
    // MARK: - Body
    
    var body: some View {
        // 组件视图
    }
}

// MARK: - Preview

#Preview {
    XXX(data: .init())
}
```

### 模型文件 (Models/XXX.swift)

```swift
import Foundation

/// 模型中文描述
struct XXX: Identifiable, Codable {
    let id: UUID
    let name: String
    let value: Double
    
    // 初始化器
    init(id: UUID = UUID(), name: String, value: Double) {
        self.id = id
        self.name = name
        self.value = value
    }
}
```

### ViewModel 文件 (ViewModels/XXXViewModel.swift)

```swift
import Foundation
import SwiftUI

/// ViewModel 中文描述
@MainActor
class XXXViewModel: ObservableObject {
    // MARK: - Published Properties
    
    @Published var items: [Item] = []
    @Published var isLoading: Bool = false
    
    // MARK: - Methods
    
    func loadData() async {
        isLoading = true
        defer { isLoading = false }
        
        // 加载数据逻辑
    }
}
```

## 命名规范

### 文件命名
- ✅ `TodayView.swift` - 视图
- ✅ `TaskRow.swift` - 组件
- ✅ `Task.swift` - 模型
- ✅ `TaskViewModel.swift` - ViewModel
- ❌ `today_view.swift` - 不要用蛇形
- ❌ `Today.swift` - 视图必须带 View 后缀

### 类型命名
- ✅ `struct Task` - 数据模型
- ✅ `class TaskViewModel` - ViewModel
- ✅ `protocol TaskService` - 协议
- ✅ `enum TaskStatus` - 枚举

### 变量命名
```swift
// ✅ 清晰描述性
let taskList: [Task]
let isCompleted: Bool
let onTaskAdded: (Task) -> Void

// ❌ 避免缩写
let tl: [Task]  // ❌
let tasks: [Task]  // ✅
```

## 添加新页面流程

### 1. 创建文件
```bash
# 在 Xcode 中:
# File → New → File... → SwiftUI View
# 命名为: XXXView.swift
```

### 2. 实现视图
```swift
import SwiftUI

struct XXXView: View {
    var body: some View {
        NavigationView {
            // 内容
        }
    }
}

#Preview {
    XXXView()
}
```

### 3. 注册到导航
编辑 `ContentView.swift`:
```swift
TabView {
    // ... 其他页面
    
    XXXView()
        .tabItem {
            Label("页面名", systemImage: "icon.name")
        }
}
```

### 4. 测试
- 按 `⌘ + R` 运行
- 按 `⌥ + ⌘ + P` 查看预览

## 添加新组件流程

### 1. 创建文件
```bash
# Components/XXX.swift
```

### 2. 实现组件
```swift
import SwiftUI

struct XXX: View {
    let data: DataType
    
    var body: some View {
        // 组件实现
    }
}

#Preview {
    XXX(data: .init())
}
```

### 3. 在视图中使用
```swift
struct MyView: View {
    var body: some View {
        VStack {
            XXX(data: someData)
        }
    }
}
```

## 资源管理

### 图片资源
```swift
// 添加到 Assets.xcassets
// 使用:
Image("imageName")
```

### 颜色资源
```swift
// 添加到 Assets.xcassets/AccentColor.colorset
// 使用:
Color.accentColor
```

### 字符串本地化 (可选)
```swift
// Localizable.strings
"welcome_message" = "欢迎使用 HOLO";

// 使用:
Text("welcome_message")
```

## Git 规范

### .gitignore (Xcode 默认)
```
.DS_Store
DerivedData/
*.xcuserstate
*.hmap
*.ipa
*.dSYM.zip
*.dSYM
```

### 提交信息
```
feat: 添加今日任务页面
fix: 修复财务卡片显示问题
refactor: 重构健康页面布局
docs: 更新 README
```

## 检查清单

创建新文件时检查:
- [ ] 文件命名符合规范
- [ ] 添加了 `#Preview`
- [ ] 添加了文档注释
- [ ] 代码使用 MARK 注释组织
- [ ] 遵循设计系统 (颜色/字体/圆角)
- [ ] 在需要的地方注册/导入

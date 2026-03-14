# SwiftUI 开发最佳实践

## 核心原则

### 1. 声明式优先
✅ **正确**:
```swift
struct ContentView: View {
    @State private var count = 0
    
    var body: some View {
        Text("Count: \(count)")
            .onTapGesture { count += 1 }
    }
}
```

❌ **错误** (命令式思维):
```swift
// 不要尝试手动更新 UI
```

### 2. 状态管理

**状态层级**:
1. **本地状态**: `@State` - 仅当前视图使用
2. **共享状态**: `@Binding` - 父子视图共享
3. **应用状态**: `@StateObject` + `ObservableObject` - 全局共享

**示例**:
```swift
// ViewModel
class TaskViewModel: ObservableObject {
    @Published var tasks: [Task] = []
    
    func addTask(_ task: Task) {
        tasks.append(task)
    }
}

// 视图
struct TaskView: View {
    @StateObject private var viewModel = TaskViewModel()
    
    var body: some View {
        List(viewModel.tasks) { task in
            Text(task.title)
        }
    }
}
```

### 3. 视图组件化

**拆分原则**:
- 超过 100 行的 `body` 考虑拆分
- 可复用的 UI 提取为独立组件
- 复杂逻辑提取为 ViewModel

**示例**:
```swift
// ❌ 太大
struct BigView: View {
    var body: some View {
        VStack {
            // 100+ 行代码...
        }
    }
}

// ✅ 拆分
struct BigView: View {
    var body: some View {
        VStack {
            HeaderSection()
            ContentSection()
            FooterSection()
        }
    }
}

struct HeaderSection: View {
    var body: some View {
        // ...
    }
}
```

## 布局技巧

### 1. 使用 ScrollView
```swift
ScrollView {
    VStack(alignment: .leading, spacing: 20) {
        // 内容
    }
    .padding()
}
```

### 2. 响应式布局
```swift
VStack {
    if UIDevice.current.userInterfaceIdiom == .pad {
        // iPad 布局
    } else {
        // iPhone 布局
    }
}
```

### 3. 安全区域
```swift
// 键盘安全区
VStack {
    // 内容
}
.ignoresSafeArea(.keyboard, edges: .bottom)

// ⚠️ 注意：顶部安全区（灵动岛/刘海）
// 顶部内容需要 padding(.top, 8~12pt) 避开灵动岛
// 不要设置 padding(.top, 0)，否则内容会被遮挡
```

### 4. 容器高度精确计算
子视图有固定高度时，容器高度必须精确计算：
```swift
// 计算公式：子元素高度 + 所有间距 + 内边距 + 缓冲
// 例：标题(16) + 间距(6) + 格子(56) + padding(8) + buffer(4) = 90
.frame(height: 90)

// ❌ 错误：估算值导致裁切
.frame(height: 70)  // 底部会被下方视图遮挡
```

### 5. 互斥视图动画
功能相似的视图展开 A 时应隐藏 B：
```swift
// revealProgress: 0~1 表示展开进度
ViewA()
    .opacity(1 - revealProgress)
    .frame(height: maxHeight * (1 - revealProgress))
    .clipped()

ViewB()
    .frame(height: maxHeight * revealProgress)
    .clipped()
```

## 性能优化

### 1. 使用 LazyVStack/LazyHStack
```swift
// 长列表使用 LazyVStack
ScrollView {
    LazyVStack {
        ForEach(items) { item in
            ItemRow(item: item)
        }
    }
}
```

### 2. 避免不必要的计算
```swift
// ❌ 每次都计算
var body: some View {
    Text(expensiveFunction())
}

// ✅ 使用 computed property 或缓存
private var cachedValue: String {
    // 计算结果
}
```

### 3. 使用 Equatable
```swift
struct ItemRow: View, Equatable {
    let item: Item
    
    var body: some View {
        Text(item.name)
    }
    
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.id == rhs.item.id
    }
}
```

## 常见模式

### 1. 列表 + 详情
```swift
NavigationSplitView {
    List(items) { item in
        NavigationLink(item.name, destination: DetailView(item: item))
    }
} detail: {
    Text("Select an item")
}
```

### 2. 表单输入
```swift
Form {
    Section("User Info") {
        TextField("Name", text: $name)
        SecureField("Password", text: $password)
    }
}
```

### 3. 模态弹窗
```swift
.alert("Title", isPresented: $showAlert) {
    Button("OK") { }
} message: {
    Text("Message")
}
```

### 4. Sheet Detent 选择
```swift
// .medium ≈ 屏幕 50%，适合简单内容
// .large ≈ 屏幕 90%，适合完整页面

// ⚠️ 如果 .medium 不够展示完整内容，使用自定义高度
.presentationDetents([.height(480), .large])

// 添加上滑提示，告知用户可以继续展开
HStack {
    Image(systemName: "chevron.up")
    Text("上滑查看更多")
}
.foregroundColor(.secondary.opacity(0.5))
```

### 5. 交互可发现性
隐藏的交互（滑动、长按、双击）需要视觉提示：
```swift
// ✅ 下拉刷新有系统提示
.refreshable { await loadData() }

// ⚠️ 自定义手势需要手动提示
DragGesture()
    .onChanged { ... }

// 配合提示文字或图标
Text("下拉展开日历")
    .font(.caption)
    .foregroundColor(.secondary)
```

## 调试技巧

### 1. 预览调试
```swift
#Preview("Dark Mode") {
    ContentView()
        .preferredColorScheme(.dark)
}

#Preview("Small Screen") {
    ContentView()
        .frame(width: 320, height: 568)
}
```

### 2. 状态检查
```swift
var body: some View {
    Content()
        .onAppear {
            print("State: \(state)")
        }
}
```

### 3. 性能分析
- 使用 Xcode 的 View Debugger
- 开启 `Debug → View Debugging → Capture View Hierarchy`

## 代码风格

### 1. 组织代码
```swift
struct MyView: View {
    // MARK: - Properties
    @State private var value: String = ""
    
    // MARK: - Body
    var body: some View {
        // ...
    }
    
    // MARK: - Private Methods
    private func helper() {
        // ...
    }
}
```

### 2. 命名规范
- 视图：`XXXView`
- 组件：`XXXComponent` 或描述性名称
- ViewModel: `XXXViewModel`
- 模型：`XXX` 或 `XXXModel`

### 3. 注释
```swift
/// 页面的简短描述
struct MyView: View {
    // MARK: - 部分说明
    
    /// 属性的用途说明
    @State private var value: String
    
    /// 方法的功能说明
    private func doSomething() {
        // 复杂逻辑的行内注释
    }
}
```

## 测试

### 1. 预览即测试
```swift
#Preview("Empty State") {
    ContentView(items: [])
}

#Preview("Loaded State") {
    ContentView(items: [
        Item(id: 1, name: "Test")
    ])
}
```

### 2. UI 测试
```swift
func testExample() throws {
    let app = XCUIApplication()
    app.launch()
    
    XCTAssertTrue(app.staticTexts["Welcome"].exists)
}
```

## 资源

- [Apple SwiftUI Tutorial](https://developer.apple.com/tutorials/swiftui)
- [SwiftUI Lab](https://swiftui-lab.com/)
- [Hacking with Swift](https://www.hackingwithswift.com/swiftui)

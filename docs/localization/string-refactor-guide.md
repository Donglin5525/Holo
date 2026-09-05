# Holo 文案本地化改造规范（批次 0 定稿）

> 适用范围：一期（zh-Hant）与二期（en）的所有文案改造工作。
> 配套词表：`Holo/Holo APP/Holo/Holo/Localizable.xcstrings`（String Catalog 格式）
> 配套术语表：`docs/localization/glossary-zh-hant.md`

## 一、词表机制

- 词表文件：`Localizable.xcstrings`，位于主 App 同步文件夹（PBXFileSystemSynchronizedRootGroup）内，**新增即自动进 target，无需改 pbxproj**
- 源语言：`zh-Hans`（developmentRegion 已是 zh-Hans，词表 sourceLanguage 已设 zh-Hans）
- **key 策略：中文原文即 key**。词表里简体文案本身就是索引，繁体/英文是它的译文列
  - 好处：抽取零成本、测试断言兼容、OpenCC 可直接对 key 列转换
  - 代价：将来改文案措辞时所有语言列要同步重译——接受此代价
- 已声明语言：zh-Hans（源）、zh-Hant、en。二期英文无需再动工程

## 二、写法改造规则

### ✅ 不需要动的（Xcode 构建时自动收进词表）

所有接受字符串**字面量**的 SwiftUI 接口（参数类型是 LocalizedStringKey）：

```swift
Text("今日支出")
Button("保存") { ... }
Label("习惯", systemImage: "checkmark")
Toggle("开启提醒", isOn: $on)
Picker("周期", selection: $sel) { ... }
TextField("输入昵称", text: $name)
SecureField("密码", text: $pwd)
.navigationTitle("财务")
.confirmationDialog("确认删除？", ...)
Text("共 \(count) 笔")          // 插值也算，count 会被编成 %lld
```

### 🔧 必须改造的（String 类型绕过了自动提取）

| 现状写法 | 改成 |
|---|---|
| `Text(someVar)`（变量间接传中文） | 变量来源处改字面量；来源是计算属性则见下一行 |
| 枚举/模型的 `var displayName: String { "工作" }` | `var displayName: String { String(localized: "工作") }` |
| `"共 " + n.description + " 笔"` 拼接 | `Text("共 \(n) 笔")` 或 `String(format: String(localized: "共 %d 笔"), n)` |
| `String(format: "第%d期", i)` | `String(format: String(localized: "第%d期"), i)` |
| 错误码→用户文案的 switch/字典 | 文案处包 `String(localized:)` |

原则：**在中文文案最终「出生」的那一行包 `String(localized:)`**，而不是在使用点层层包裹。

### 🚫 不进 UI 词表的（单独管理）

| 内容 | 管理方式 |
|---|---|
| AI 提示词（PromptManager.swift 等） | 按语言分常量文件管理（批次 2 处理），不混入 UI 词表 |
| 日志、assert 信息 | 保持原样 |
| 测试断言 | 继续写中文原文（zh-Hans 环境渲染结果 = key = 原文，不受影响） |
| 代码注释 | 不动 |

## 三、批次流程（每个模块重复此循环）

1. 改造该模块代码写法（按上表规则）
2. `build_sim` 编译 → 构建过程自动把新字面量收进 xcstrings（简体列长出来）
3. 跑 `docs/localization/fill-zh-hant.sh` 填繁体列（OpenCC s2twp）
4. 按术语表核对产品词与陷阱字（历/歷曆、账/帳、里/裡、后/後）
5. 跑该模块测试 + 模拟器切繁体冒烟
6. 小步提交，commit 里附 xcstrings diff 供审

## 四、专项注意

- **小组件（HoloWidgets target）不是同步文件夹**：新建它的 xcstrings 后必须手动挂 pbxproj（PBXFileReference + Resources BuildPhase），否则静默不生效——参考 HoloTests 手动挂载的老坑
- **日期格式**：`yyyy年MM月dd日` 类写死格式改为 `DateFormatter` + `setLocalizedDateFormatFromTemplate("yMMMd")`，随系统语言自动变
- **货币**：一期维持 ¥ 人民币显示不动，仅数字格式随系统；多币种是独立项目
- **不润色**：改造只换「包装写法」，不改文案措辞本身；措辞调整独立立项，避免词表 key 频繁变动连坐重译

## 五、禁止事项

1. 不手写 xcstrings 的简体条目——只让构建自动提取，防止漏改代码只填表（出现「表里有、代码里没有」的假翻译）
2. 不用 `NSLocalizedString` 老 API，统一 `String(localized:)`
3. 不在改造 PR 里顺手改文案内容
4. 不把英文列提前填进词表（二期统一做，避免半成品翻译漂移）

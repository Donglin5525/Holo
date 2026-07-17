# XCTest 环境下 CoreData 测试的三个坑（2026-07-17）

> 来源：观点标签全局管理功能（`ThoughtRepositoryTagManagementTests`）落地过程。
> 三个坑按发现顺序排列，都是 hosted test（测试注入 app 进程运行）环境下特有的。

---

## 坑 1：HoloTests target 是显式文件引用，新测试文件不会自动进 target

**现象**：`xcodebuild test -only-testing:...` 报 `Executed 0 tests` 但 TEST SUCCEEDED。

**根因**：`Holo.xcodeproj` 里只有主 target `Holo` 是 `PBXFileSystemSynchronizedRootGroup`（文件系统同步组），**HoloTests 仍是传统 PBXFileReference 显式列表**。新测试文件放进 HoloTests/ 目录不会被编译。

**修复**：向 pbxproj 手工插入四件套（PBXBuildFile + PBXFileReference + group children + HoloTests Sources phase files），HoloTests 的 Sources phase ID 是 `6246BF929F91C28DF1408636`，测试分组按磁盘目录对应（如 HoloTests/Services/AI → group `01FEFE4BD64B0BA4926A551E`）。

**遗留事实**：`HoloTests/Services/AI/ThoughtRepositoryAITagBucketTests.swift`、`HoloTests/Services/Calendar/*RepositoryCalendarTests.swift` 等一批测试文件**从未挂进 target，从未运行过**。是否补挂待决策。

---

## 坑 2：hosted test 中内存 CoreData + XCTest executor 的 malloc 崩溃

**现象**：测试用例之间进程崩溃：`malloc: *** error for object 0x...: pointer being freed was not allocated`，崩溃帧含 `swift_task_deinitOnExecutor... → swift::TaskLocal::StopLookupScope::~StopLookupScope()`。

**根因**：XCTest 包装测试方法的 task 在与其创建不同的 executor 上析构时，释放持有的局部对象会触发 Swift Concurrency runtime 的 TaskLocal double-free（Apple 已知问题）。同步测试方法、`@MainActor` 同步测试方法、有 `await` 挂起点的 async 方法都容易中招。

**稳定模式（已验证）**：测试方法用 `async throws` 且方法体内**无 await 挂起点**，CoreData 对象在测试 task 内创建并释放（cooperative pool executor 路径），不崩。项目里真正在跑的 CoreData 测试（`ChatMessageRepositoryCacheRecoveryTests`）用的是另一条路：直接用 `CoreDataStack.shared` 真实库 + setUp/tearDown 清数据。

**附带噪音**：hosted 环境下 app 的 model 与测试 `createDataModel()` 新建的 model 双注册，CoreData 会打 `Failed to find a unique match for an NSEntityDescription` error 日志——**是噪音，不致命**，不影响测试正确性。

---

## 坑 3（根因坑）：测试里 post `thoughtDataDidChange` 通知 → app 观察者并发刷新 → 必崩

**现象**：Service 测试第一个用例 passed 之后、第二个用例开始前**必崩**（double-free，固定地址）；单独跑任一用例都正常；改测试结构（@MainActor / defer 释放 / MainActor job 收敛）全部无效。

**根因**：测试调用的 Service 方法里 `NotificationCenter.default.post(name: .thoughtDataDidChange)` 被 **app 侧的 6 个观察者**（MemoryGalleryViewModel、ThoughtListView、HomeScheduleService、EffectiveRecordDayService、HoloWidgetSnapshotService 等）收到，它们在 app 进程里并发启动刷新 Task，与 XCTest 的 task 管理交互，触发坑 2 同源的 runtime double-free。**崩溃与测试体写什么无关，只与「测试进程发出了通知」有关**。

**修复（也是项目既有惯例）**：Service 层方法**不 post 数据变更通知，由调用方（UI）负责**——与 `rejectAndRecord` / `confirmAssignment` 的现状一致（详情页调完后自己 `loadData()`）。本次把 `deleteTagEverywhere` / `renameTagEverywhere` 的通知挪到抽屉 UI 的 `performRename` / `performDelete` 里 post 后，16/16 测试稳定全绿。

**规则**：后续写「会触发 app 通知」的 Service 方法时，通知一律放 UI 调用方 post；Service 保持安静，否则 hosted test 无法覆盖该方法。

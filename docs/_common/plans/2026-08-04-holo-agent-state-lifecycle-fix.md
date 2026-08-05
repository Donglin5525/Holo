# HoloAI 对话任务状态与前后台恢复修复

## 产品结论

HoloAI 的“消息卡片仍保留”和“任务仍在执行”必须分开。系统收回后台执行权不是分析失败，也不是用户主动暂停；它应进入可恢复等待，回到 Holo 后从 checkpoint 自动继续。用户点击停止才进入取消终态，旧任务不得重新打开消息。

## 决策记录

### 统一状态语义

- `waitingForForeground + systemCapacity`：系统等待，回到 Holo 自动恢复。
- `waitingForCondition`：设备、网络等条件等待，条件恢复后继续。
- `paused + userPaused`：未来用户主动暂停，不能自动恢复。
- `cancelled / completed / failed / superseded`：终态，不再接受旧进度回写。

历史上错误落盘的 `paused + systemCapacity` 兼容纳入自动恢复集合。

### UI 表现

`keepsMessageStreaming` 继续表示“保留消息卡片”，新增的 `isExecutionActive` 才决定输入栏和停止按钮。等待卡片保留，但输入栏恢复发送按钮；状态解析补齐“分析已暂停”和系统等待文案。

### 恢复与竞态

每次回到前台统一执行 Scheduler 恢复链。`runOrAttach` 保证仍在运行的任务不会重复启动；等待任务从 checkpoint 接续。停止后的“已停止生成”消息被视为本地终态，旧 Job 的同步和结果回填不得覆盖。

## 验收边界

定向测试验证 Job 状态迁移、旧任务兼容恢复、状态文案和停止终态护栏；Continued Processing 的系统卡片与真实前后台时序仍需 iOS 26 真机验证。

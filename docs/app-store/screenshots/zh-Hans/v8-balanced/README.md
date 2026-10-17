# 简体中文商店截图（五模块平衡版）

App Store Connect 当前顺序：生活首页、任务统计、习惯、想法、健康、记账输入、AI 记账分析、任务热力图、记忆回放。前五张先呈现首页与任务、习惯、想法、健康，避免产品页开头连续聚焦记账。

任务、习惯与健康截图由 iPhone 模拟器运行当前 App 界面拍摄；任务统计、任务热力图和健康页使用虚构演示数据，不来自真实用户账户。习惯页展示 5 项演示习惯当天已记录。原 v7 素材未覆盖，v8 是本次五模块平衡版。

`upload/iphone-medium/default/` 为上传素材；`raw/iphone-medium/` 保留新增截图的原始 App 画面。新增素材可通过以下命令重新排版：

```sh
swift scripts/render_app_store_balanced_extras.swift "$PWD"
```

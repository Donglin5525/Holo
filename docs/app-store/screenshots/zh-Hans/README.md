# Holo App Store 宣传图（简体中文）

## 展示顺序

1. 把散落的生活，放进同一个 Holo —— 财务、习惯、任务、观点与健康统一呈现
2. 说一句，三件事都办好 —— 一次完成记账、建待办和习惯打卡
3. 问一句，再继续追问 —— Agent 记得上一轮上下文，跨模块读取记录，回答会随着问题继续深入
4. 用一张日历，复盘每天发生了什么 —— 把不同类型的记录放回同一条生活时间线
5. 看见消费变化，也看见生活节奏 —— 统计不止报金额，也帮助理解变化
6. 把今天的记录，变成长期变化 —— AI 回放与长期记忆持续呈现正在形成的习惯

## 目录与规格

- `iphone-6.9/raw/`：iPhone 17 Pro Max 模拟器原始截图，1320 × 2868
- `iphone-6.9/final/`：iPhone 6.9 英寸宣传成片，1320 × 2868
- `ipad-13/raw/`：iPad Pro 13 英寸模拟器原始截图，2064 × 2752
- `ipad-13/final/`：iPad 13 英寸宣传成片，2064 × 2752
- `upload-ready/iphone-6.9/`：可直接上传的 iPhone 成片
- `upload-ready/ipad-13/`：可直接上传的 iPad 成片

成片必须为 PNG、无透明通道，并保持 `01` 到 `06` 的文件顺序。

本轮成片中的数据全部是 Debug 截图模式生成的虚构演示数据；页面展示的是 App 内真实界面，不是脱离 App 的功能海报。

## 可复现截图模式

截图数据仅在 Debug 模拟器中、且进程环境变量
`HOLO_APP_STORE_SCREENSHOT_MODE=1` 时生成；Release 构建不会包含截图数据入口。

## 重新渲染

```bash
xcrun swift scripts/render_app_store_screenshots.swift "$PWD"
xcrun swift scripts/render_app_store_screenshots.swift "$PWD" ipad
```

宣传图上传到 App Store Connect 的版本页面；Xcode 只负责归档和上传 App 构建，不存放商店宣传截图。

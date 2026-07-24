# Holo App Store 宣传图（简体中文）

## 展示顺序

1. 把散落的生活，放进同一个 Holo
2. 说一句，三件事都办好
3. 问自己的数据，得到真正有用的回答
4. 用一张日历，复盘每天发生了什么
5. 看见消费变化，也看见生活节奏
6. 把今天的记录，变成长期变化

## 目录与规格

- `iphone-6.9/raw/`：iPhone 17 Pro Max 模拟器原始截图，1320 × 2868
- `iphone-6.9/final/`：iPhone 6.9 英寸宣传成片，1320 × 2868
- `ipad-13/raw/`：iPad Pro 13 英寸模拟器原始截图，2064 × 2752
- `ipad-13/final/`：iPad 13 英寸宣传成片，2064 × 2752

成片必须为 PNG、无透明通道，并保持 `01` 到 `06` 的文件顺序。

## 可复现截图模式

截图数据仅在 Debug 模拟器中、且进程环境变量
`HOLO_APP_STORE_SCREENSHOT_MODE=1` 时生成；Release 构建不会包含截图数据入口。

## 重新渲染

```bash
xcrun swift scripts/render_app_store_screenshots.swift "$PWD"
xcrun swift scripts/render_app_store_screenshots.swift "$PWD" ipad
```

宣传图上传到 App Store Connect 的版本页面；Xcode 只负责归档和上传 App 构建，不存放商店宣传截图。

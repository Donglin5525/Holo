# Holo App Store 截图 v5：生活化真实场景

这组素材不是文生图。六张原图均由 Holo Debug 版本在 `Holo App Store 6.9` iOS 模拟器中运行后，通过 `HoloXhsShotUITests` 截取，尺寸为 1320 × 2868；外层宣传文案只由 `scripts/render_app_store_screenshots.swift life` 确定性合成。

## 场景主线

同一套 `life-flow` 模拟数据贯穿六张图：下周二项目周会、周四准备签证材料、给爸妈买药 ¥128、会议与出行准备的时间分析、会议前留缓冲的候选记忆，以及记忆长廊里的生活回放。第六张的“开完会去喝杯咖啡”想法挂载了三张真实照片（咖啡、甜点、天空），由 Holo 的多图想法卡直接渲染。

## 文件

- `iphone-6.9/raw/`：模拟器直接截图，不含宣传标题。
- `iphone-6.9/final/`：App Store 介绍图，外框文案与 raw 中的真实 Holo 界面一一对应。

## 复现

在 Debug 模式下运行 `HoloXhsShots` scheme，并设置：

```text
HOLO_APP_STORE_SCREENSHOT_MODE=1
HOLO_APP_STORE_SCREENSHOT_STORY=life-flow
```

六个 UI 测试方法为 `testShotLifeFlow01Actions` 至 `testShotLifeFlow06MemoryGallery`。生成原图后运行：

```text
xcrun swift scripts/render_app_store_screenshots.swift "$PWD" life
```

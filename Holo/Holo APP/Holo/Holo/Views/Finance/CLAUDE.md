# 财务模块

## 模块结构

```
Finance/
├── CLAUDE.md
├── FinanceAnalysisState.swift   — 分析页状态管理
├── MonthlySummaryCard.swift     — 月度汇总卡片
├── Analysis/
│   ├── CategoryTabView.swift    — 类别 Tab（饼图 + 图例 + 下钻）
│   ├── OverviewTabView.swift    — 概览 Tab（TOP3 卡片）
│   ├── TrendTabView.swift       — 趋势 Tab（折线图）
│   └── Components/
│       ├── PieChartView.swift   — 环形饼图（Canvas 自绘）
│       └── ...
└── ...
```

## 编码约定

### Canvas 自绘组件规则

- **所有坐标/角度计算必须共享同一个转换函数**，禁止画图和交互各算各的。如果画扇形用了一套角度约定，标签线和触摸检测必须用同一套，否则必然漂移。

### PieChartView 角度约定

修改饼图相关逻辑前必须理解以下坐标系：

| 概念 | 约定 |
|------|------|
| 逻辑角度起点 | `sectorStartAngle` 从 **-90°**（12 点钟）开始顺时针累加 |
| addArc 绘制 | 使用 **`-startDeg`** 取反 + `clockwise: true` |
| 标签/触摸/凸出偏移 | 必须使用 **`-midDeg`** 计算方向向量（匹配 addArc 视觉位置） |
| 坐标系 | 0° = 右（3 点钟），cos → X，sin → Y 向下 |

关键公式：
```swift
// 扇区中点方向（匹配 addArc 视觉位置）
let drawMidRad = -midDeg * .pi / 180
let cosMid = CGFloat(cos(drawMidRad))  // X 分量
let sinMid = CGFloat(sin(drawMidRad))  // Y 分量（注意：与未取反的 sin 符号相反）
```

> **为什么取反**：`addArc` 接收 `-startDeg`，所以扇区的视觉中点在 `-midDeg` 方向。如果标签用未取反的 `midDeg`，则 cos(-x)=cos(x) 不变，但 sin(-x)=-sin(x) 导致 **Y 分量翻转** — 标签和扇区在上下方向正好反过来。

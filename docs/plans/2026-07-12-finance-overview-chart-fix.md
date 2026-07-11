# 财务总览图表修复 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 修复财务总览图中收支柱堆叠、余额线压缩和首尾贴边问题，使不同量级的数据都能正常阅读。

**Architecture:** 保留现有 `ChartDataPoint` 数据流，在 `BarChartView` 内将收支柱按同一日期分组并排显示；继续把余额映射到收支绘图区，但增加稳定的右轴/绘图区留白与可读性约束。用纯逻辑测试守住柱图布局参数和坐标刻度行为。

**Tech Stack:** SwiftUI, Swift Charts, XCTest standalone/project tests.

---

### Task 1: 修复总览图绘制布局

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/Finance/Analysis/Components/BarChartView.swift`

**Steps:**
1. 为同一日期的收入/支出提供明确的并排 series 分组，避免 Swift Charts 自动堆叠。
2. 给 X 轴增加首尾绘图区留白，并按数据量限制柱宽，避免首个柱被裁切或少量数据挤成大块。
3. 保持余额线点位与右轴刻度的映射一致，避免大额柱让折线失去可读性。
4. 检查 tooltip、触摸命中和空状态不被布局调整破坏。

### Task 2: 增加回归测试并验证

**Files:**
- Modify: `Holo/Holo APP/Holo/HoloTests/Models/FinanceChartScaleTests.swift`

**Steps:**
1. 增加图表布局参数/刻度的纯逻辑断言，覆盖少量数据、首尾留白和双轴范围。
2. 运行相关测试；再执行 iOS 工程构建，确认 Swift Charts 调用和现有脏改不冲突。

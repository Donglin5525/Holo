# 财务模块图标 v3 全量替换 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将压缩包中的全部财务 SVG 接入 iOS 财务模块，替换现有默认图标并补入新增默认科目，同时保持现有功能和图片规格。

**Architecture:** 资源进入 `Assets.xcassets` 的矢量 imageset；分类图标统一从 `categoryIconGlyph` 渲染。默认科目目录负责业务名称与图标绑定，兼容迁移负责历史分类值，三者通过稳定的 `finance.<key>` 资源名连接。

**Tech Stack:** SwiftUI, Xcode Asset Catalog, Core Data, standalone Swift assertions.

---

### Task 1: 盘点并导入矢量资源

**Files:**
- Create: `Holo/Holo APP/Holo/Holo/Assets.xcassets/CategoryIcons/finance.<key>.imageset/*`
- Source: `/Users/tangyuxuan/Downloads/holo_finance_icons_v3_final.zip`

**Steps:**
1. 解压到临时目录，按 `icon_matches.json` 核对 84 个 key。
2. 为每个 key 生成 SVG imageset，保留原 SVG viewBox，配置 universal + template + vector representation。
3. 检查文件名、Contents.json 和 SVG 数量完全一致。

### Task 2: 接入统一图标渲染

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Models/Category+Icon.swift`

**Steps:**
1. 增加 `finance.` 资源名识别分支。
2. 使用模板渲染资源，沿用现有颜色和 `size * 0.6` 尺寸规则。
3. 保留 SF Symbols、自绘旧图标和用户自定义 `icon_` 回退路径。

### Task 3: 更新默认科目和选择器

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Models/Category+CoreDataProperties.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Components/CategoryIconCatalog.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Models/Category+Icon.swift`

**Steps:**
1. 将映射表已有默认科目切换至 `finance.<key>`。
2. 将压缩包 label 中缺失的新增支出/收入科目补入默认目录，按既有一级分类与颜色归组。
3. 将所有新资源加入图标选择器目录，并保留现有图标。
4. 保持默认科目初始化幂等，不覆盖用户已编辑的分类。

### Task 4: 历史数据兼容和测试

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Models/Category+CoreDataProperties.swift`
- Create/Modify: `Holo/Holo APP/Holo/HoloTests/Finance/*`（若项目现有测试结构允许）

**Steps:**
1. 扩展旧语义图标迁移映射，确保旧 `icon_*` 与旧 SF Symbol 分类可显示。
2. 增加资源 key、label、默认目录覆盖率断言。
3. 运行 standalone 断言与 `build_sim`，确认不触碰记账功能链路。

### Task 5: 收尾检查

**Steps:**
1. 检查 `git diff` 仅包含财务图标资源、映射、目录和计划文档。
2. 确认未覆盖东林现有未提交改动。
3. 汇报资源数量、新增科目数量、验证结果和任何需手动在 Xcode 中确认的事项。

# 财务模块图标 v3 全量替换设计

## 产品结论

将压缩包内全部财务 SVG 作为默认财务科目的新图标，统一替换现有 SF Symbols/旧自绘图标，并把映射表中的新增科目加入默认科目目录。用户看到的是更统一的图标风格；记账数据、科目名称、颜色、尺寸和既有功能保持不变。

## 产品决策

- 以 `icon_matches.json` 的中文 `label` 作为默认科目名称与图标绑定依据。
- SVG 以 Xcode Asset Catalog 的矢量模板资源接入，保留透明背景、单色模板着色和现有调用尺寸。
- 不改交易模型、Core Data 字段、记账流程和历史数据结构。
- 通过一次性迁移把已有默认科目切换到新资源名；用户自定义 `icon_` 图标继续安全回退。

## 技术设计

1. 为每个 `finance_*.svg` 生成对应 imageset，启用 `preserves-vector-representation` 和 template rendering。
2. `categoryIconGlyph` 增加 `finance.*` 资源分支，使用 `Image` 加模板渲染；SF Symbols 继续走原分支。
3. 扩展默认支出/收入科目目录，补入压缩包中当前目录没有的科目，并为已有科目替换图标名。
4. 增加新资源名到旧语义/历史图标的兼容映射，避免已有 Core Data 分类失去图标。
5. 更新图标选择器目录，保留原有 SF Symbols，同时加入新财务资源供自定义分类使用。

## 验证

- 压缩包资源与 Asset Catalog 文件一一对应，无缺失或重复。
- 所有默认科目均引用存在的 `finance.*` 资源。
- 资源 SVG 保持 256 视图框、透明背景和可模板着色。
- standalone 映射断言通过，Xcode 工程 BUILD SUCCEEDED。

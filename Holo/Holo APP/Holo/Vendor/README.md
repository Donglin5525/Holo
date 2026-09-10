# Vendor 本地依赖包

网络环境原因（GitHub 访问不稳定），以下第三方依赖以本地 Swift Package 形式随仓库维护：

| 包 | 版本 | 上游 |
|---|---|---|
| CoreXLSX | 0.14.2 | https://github.com/CoreOffice/CoreXLSX |
| ZIPFoundation | 0.9.20 | https://github.com/weichsel/ZIPFoundation |
| XMLCoder | 0.14.0 | https://github.com/maxdesiatov/XMLCoder |
| USearch | 2.26.2 | https://github.com/unum-cloud/USearch |
| NumKong | 7.8.2 (6de303be) | https://github.com/ashvardanian/NumKong |

用途：账单智能导入（xlsx 读取 / zip 解压）；想法本地语义索引 V3（HNSW 向量检索）。
CoreXLSX 的 Package.swift 已把 XMLCoder、ZIPFoundation 改为本地路径依赖
（../XMLCoder、../ZIPFoundation）；USearch 的 Package.swift 已把 NumKong 改为
本地路径依赖（../NumKong）。

## NumKong 本地补丁（重要）

`NumKong/include/numkong_vendor_compat.c` 是一个只有注释的空源文件——
NumKong 的 CNumKong target 是纯头文件（header-only）库，Xcode 的 SPM 集成
会为它生成不存在的 `CNumKong.o` 链接产物，导致任何经 xcodebuild 链接
USearch 的 target 构建失败（SwiftPM 原生构建不受影响）。该空文件让 CNumKong
有真实编译产物。**升级 NumKong 前先验证上游是否已修复；若已修复，删除此
文件即可回到上游行为。**

升级方法：在上游拉取新版本覆盖对应目录（删除 .git），重跑 CoreXLSX 的本地化
改造（Package.swift 的两行 path 依赖）与 USearch 的本地化改造（Package.swift
一行 path 依赖 + 确认 numkong_vendor_compat.c 是否仍需保留），然后构建验证。
USearch 升级属于高风险操作（Swift API 曾与文档漂移，见
docs/thoughts/plans/2026-09-10-想法语义索引选型ADR-USearch.md），必须重跑
spike 性能门禁。


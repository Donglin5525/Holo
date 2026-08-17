# Vendor 本地依赖包

网络环境原因（GitHub 访问不稳定），以下第三方依赖以本地 Swift Package 形式随仓库维护：

| 包 | 版本 | 上游 |
|---|---|---|
| CoreXLSX | 0.14.2 | https://github.com/CoreOffice/CoreXLSX |
| ZIPFoundation | 0.9.20 | https://github.com/weichsel/ZIPFoundation |
| XMLCoder | 0.14.0 | https://github.com/maxdesiatov/XMLCoder |

用途：账单智能导入（xlsx 读取 / zip 解压）。CoreXLSX 的 Package.swift 已把
XMLCoder、ZIPFoundation 改为本地路径依赖（../XMLCoder、../ZIPFoundation）。

升级方法：在上游拉取新版本覆盖对应目录（删除 .git），重跑 CoreXLSX 的本地化
改造（Package.swift 的两行 path 依赖），然后构建验证。

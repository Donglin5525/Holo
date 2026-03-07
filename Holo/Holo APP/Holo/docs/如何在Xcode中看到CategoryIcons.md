# 在 Xcode 里看到 CategoryIcons

CategoryIcons **不在** 左侧项目导航的顶层，而是 **在 Assets.xcassets 里面**。按下面步骤操作即可看到。

## 1. 确认文件确实在磁盘上

在终端或 Finder 中打开：

```
Holo/Holo APP/Holo/Holo/Assets.xcassets/
```

确认里面有一个叫 **CategoryIcons** 的文件夹，点进去能看到很多 `icon_xxx.imageset`。

## 2. 在 Xcode 里打开资源库

1. 在 Xcode **左侧项目导航** 里，展开 **Holo** 组。
2. 找到 **Assets.xcassets**，**单击** 选中它（不要双击）。
3. 中间编辑区会变成 **资源库（Asset Catalog）** 的界面。

## 3. 在资源库里找 CategoryIcons

资源库 **左侧** 会有一列列表，一般包括：

- **AppIcon**
- **AccentColor**
- **CategoryIcons**  ← 在这里

如果列表里没有 **CategoryIcons**，可以试试：

- 在资源库左侧空白处 **右键** → 看是否有 “Refresh” 或类似选项。
- **关闭 Xcode**，再重新打开项目，然后再次点选 **Assets.xcassets** 看左侧列表。
- 菜单栏 **Product → Clean Build Folder**，再点一次 **Assets.xcassets**。

## 4. 若仍然看不到

在 Xcode 里：

1. 在左侧项目导航里 **右键** 点击 **Assets.xcassets**。
2. 选 **Show in Finder**，会打开该资源库在磁盘上的文件夹。
3. 在 Finder 里看是否有 **CategoryIcons** 文件夹。

- **若有**：说明文件在，只是 Xcode 资源库界面没刷新，可再试一次关闭/重开 Xcode 或 Clean Build。
- **若无**：说明当前选中的 **Assets.xcassets** 不是 `Holo/Holo APP/Holo/Holo/Assets.xcassets`，可能打开的是别的 target 或别的工程下的 Assets，需要在项目导航里确认你选的是 **Holo** target 下的那一个 **Assets.xcassets**。

---

**总结**：CategoryIcons 是 **Assets.xcassets 里的一个分组**，要 **先点选 Assets.xcassets**，再在 **资源库左侧列表** 里找 “CategoryIcons”，而不是在项目导航的顶层找单独一个 “CategoryIcons” 项。

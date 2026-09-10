# Holo App Store 宣传图 v2（基于 1.0.3 能力重新规划）

2026-09-10 制作。设计源文件为 HTML，用 Chrome headless 渲染成 PNG。
成品目录：`iphone-6.9/final/`（1320×2868）与 `ipad-13/final/`（2064×2752），PNG 无透明通道，按 `01`-`06` 顺序上传 ASC。

## 六图叙事：说一句，它替你办好；问一句，它帮你读懂

| # | 卖点 | 标题 | 画面素材 |
|---|------|------|----------|
| 01 | AI 替你动手（开场钩子） | 说一句话，三件事都办好 | HoloAI 对话：一句话 → 记账/提醒/打卡三张结果卡 |
| 02 | 全景定位 | 你的全部生活，装进一个 Holo | 六域能力卡片墙（CSS 绘制，健康卡带「新」徽章体现 1.0.3） |
| 03 | AI 数据问答 | 你问一句，它引用记录回答 | 多轮问答 +「引用了你 2 条记忆」 |
| 04 | 月度回放 | 每个月，它替你复盘生活 | 用户气泡「查看本月回放」→ 跨域回放大卡 + 能力胶囊行 |
| 05 | AI 账单分析 | 支出为什么变高，它给出结论（iPad 版：钱花在哪，一问就知道） | 账单分析结论 sheet（核心结论+事实+财务概览） |
| 06 | 记忆长廊（情感收尾） | 记下的日子，长成回忆 | 长廊日期头 + 照片堆叠 + 小确幸文字 |

与旧版（upload-ready）的关键差异：
1. 砍掉空旷的全息球首页开场 → 最强卖点「AI 一句话执行」前置。
2. 砍掉信息密、缩略图不可读的周历网格 → 六域卡片墙，健康能力首次出场。
3. 所有截图从「整屏缩小」改为「关键卡片裁剪放大」，缩略图可读性质变。
4. 修复旧版执行伤：03 残影（旧版背景复用了 02 的截图且金额不一致）、05 惨淡演示数据（¥0 收入）。

## 重新渲染

```sh
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
BASE="…/docs/app-store/screenshots/zh-Hans"
# iPhone
for f in "$BASE"/v2/design/0*.html; do
  "$CHROME" --headless=new --disable-gpu --force-device-scale-factor=1 --hide-scrollbars \
    --window-size=1320,2868 --screenshot="$BASE/v2/iphone-6.9/final/$(basename "$f" .html).png" "file://$f"
done
# iPad（design/ipad/ 下同理，--window-size=2064,2752）
```

## 目录结构

- `design/`：iPhone 版 HTML 设计稿 + `design.css` 共享版式；`design/grid.html`、`design/thumb.html` 是素材坐标标定工具（?img=文件名&dir=iphone|ipad）
- `design/ipad/`：iPad 版 HTML 设计稿
- `assets/`：从旧素材库拷入的 raw 模拟器截图（iPhone 1320×2868 / iPad 2064×2752）
- `iphone-6.9/final/`、`ipad-13/final/`：成品

## 素材来源与已知缺口

- raw 素材取自 `../iphone-6.9/raw/`、`../candidates/a|b/…/raw/`（2026-08 演示数据截图）。
- ⚠️ `../ipad-13/raw/03-ai-analysis.png` 是 `02-ai-actions.png` 的复制品（md5 相同，旧素材库的坑），已改用 candidates/b 下的完好版本。
- **缺口：健康模块没有截图素材**。HealthKit 数据无法用现有 seeder 生成，本轮健康仅以 02 卡片墙的「新」徽章体现。后续如需健康整图：需在 App 内以 debug 通道向模拟器 HealthKit 写入睡眠/活动样本后截图，替换或新增第七图。
- 演示数据如需更新：Debug 构建 + 启动环境变量 `HOLO_APP_STORE_SCREENSHOT_MODE=1`（见 `HoloAppStoreScreenshotSeeder.swift`），重截后仅需替换 `assets/` 并重渲。

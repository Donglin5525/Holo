# CHANGELOG

## 2026-05-19

### fix
- **站立数据改用 Apple Stand Hour 类别类型** — 之前用 `appleStandTime` 分钟数除以60，与 Apple Watch 站立环数据不一致；改用 `appleStandHour` 类别样本直接统计达标站立小时数，数据更准确

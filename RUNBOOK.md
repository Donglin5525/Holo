# Holo 运行手册

## 后端发布前

1. 确认 diff 只包含本次范围，生产远端仍是预期仓库和分支。
2. 执行 `npm test --prefix HoloBackend`。
3. 检查 `.env.example` 与生产配置要求；不得复制本地 `.env`。
4. rsync 必须排除 `node_modules`、`.env`、`deploy/.env.production*` 和 `deploy/data`。
5. ECS 发布前加锁并备份 SQLite；使用项目 `deploy/deploy.sh`，国内环境采用 classic builder 路径。

## 发布验收

```bash
curl -fsS https://api.holoapp.cn/v1/live
curl -fsS https://api.holoapp.cn/v1/ready
curl -fsS https://api.holoapp.cn/v1/release/status
curl -fsS https://api.holoapp.cn/v1/prompts/meta
```

随后执行 `HoloBackend/scripts/verify-production-release.sh`，并验证至少一条真实 AI 拒绝路径和一条成功路径。健康接口通过不等于业务已经生效。

## 回滚

回滚必须同时考虑代码镜像、数据库 migration 是否向后兼容、Prompt Registry 当前版本和 App 客户端契约。不可直接覆盖或删除生产数据库；先停止写入、保留现场、恢复已验证备份，再逐项检查 ready 与业务请求。

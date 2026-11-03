# 已退役的部署技能版本（只读留档）

2026-10-20 跨平台配置审计（docs/_common/plans/2026-10-20-AI上下文配置系统审计与跨平台合并处理建议.md，A01/A02）后，三个并存的 `holo-backend-deploy` 版本合并为 `../holo-backend-deploy/`（唯一真源）。本目录保留被替换的两份原件供对照，**不要再按它们执行**：

- `holo-backend-deploy.claude-zcode-shared-0721/` — 原 `~/.claude/skills/holo-backend-deploy`（`~/.zcode/skills` 软链到它）。ECS `git fetch origin` 依赖 GitHub；脏树逐文件诊断逻辑已并入真源；`git add 目录 → 普通 commit` 的夹带风险已在真源修复。
- `holo-backend-deploy.project-rsync-0711/` — 原 `~/Desktop/Claude/.agents/skills/holo-backend-deploy`。rsync + flock + verify:prod 分层验收已并入真源；`cp` 热拷贝 WAL 数据库的备份方式已在真源改为在线备份 API。
- Codex 自有副本 `~/.codex/skills/holo-backend-deploy/`（ECS `git pull --ff-only`）由 Codex 自行退役并软链到真源（见 Codex 交接任务书）。

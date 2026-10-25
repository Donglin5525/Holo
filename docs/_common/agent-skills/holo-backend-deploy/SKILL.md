---
name: holo-backend-deploy
description: "Holo 后端（HoloBackend，Node.js/Hono）发布到阿里云 ECS 生产环境的唯一标准流程。用户说部署后端、发版后端、同步服务器、上线后端、后端代码准备好了时使用。流程：本地测试→按路径范围提交→直推 ECS（不依赖 GitHub）→互斥锁→SQLite 一致性备份→项目 deploy.sh→生产库保护断言→本机/公网健康→verify:prod 分层验收。三宿主（ZCode/Codex/Claude Code）共用本真源，不要另写并行流程。"
metadata:
  short-description: "稳定发布 HoloBackend 并完成线上验收（三宿主唯一真源）"
  source-of-truth: "docs/_common/agent-skills/holo-backend-deploy/"
  merged-on: "2026-10-20"
---

# HoloBackend 稳定发布（唯一真源）

> 2026-10-20 跨平台配置审计后，三个并存的部署技能版本合并为本份，放在仓库里随代码走；`~/.claude/skills`、`~/.zcode/skills`、`~/Desktop/Claude/.agents/skills`、`~/.codex/skills` 下的同名目录都应是指向这里的软链。**发现任何一处不是软链、或内容与本文不同，先停下报告，不要按旧版执行。**

目标：每次发布都能回答——部署的是哪个 commit、代码是否完整到位、容器是否真的在用新代码、线上入口是否生效、生产数据库是否完好。

原则：能复用项目脚本就不手写并行流程。`HoloBackend/deploy/deploy.sh` 负责服务器端构建/启动/发布身份/基础健康检查，`npm run verify:prod` 负责公网分层验收；本技能的脚本只补它们没覆盖的：授权闸门、提交范围守卫、GitHub 无关的同步、互斥锁、一致性备份、生产库保护断言、长构建防掐断、健康轮询。

## 固定环境

- 本地仓库：`/Users/tangyuxuan/Desktop/Claude/HOLO`；后端目录 `HoloBackend/`
- 项目脚本：`HoloBackend/deploy/deploy.sh`、`HoloBackend/scripts/verify-production-release.sh`（`npm run verify:prod`）、`smoke-test.sh`（`npm run smoke`）
- ECS：`root@123.56.104.9`，仓库 `/root/Holo`，**compose 目录永远是 `/root/Holo/HoloBackend/deploy`**（10-19 曾因用错 `/opt` 下的旧副本导致生产库脱挂；`/opt` 副本已物理停用）
- 生产 SQLite：`/root/Holo/HoloBackend/deploy/data/holo-backend.db`（WAL 模式；**未跟踪目录，绝不能被 git clean / rsync --delete 波及**）
- 公网入口：`https://api.holoapp.cn`（`123.56.104.9:8787` 只是 ECS 本机端口，不能当公网验收依据）

## 执行前规则

1. **只有东林明确要求发版才执行**。诊断、检查、看日志一律不做远程写操作。脚本本身有闸门：必须带 `HOLO_DEPLOY_CONFIRM=yes` 才会动。
2. 发布前说清本次后端改动范围（Prompt / 路由 / 依赖 / Docker / 配置），并提醒「后端改动需要发版」是协作约定，但提醒 ≠ 授权。
3. 不读取、打印、询问 `.env.production`、API Key、管理员密码等秘密。
4. 提交只允许 `HoloBackend/` 路径范围（脚本按 pathspec 提交并事后断言）；不得带入 iOS、文档、临时文件。
5. **绝不在 ECS 跑 `git clean`**（2026-08-23 曾把生产库目录删掉，靠 `/proc/PID/fd` 救回）；脚本只用 `reset --hard`，它不碰未跟踪的 `deploy/data/`。
6. 不绕过 `deploy.sh` 手敲 `docker compose build --no-cache`：BuildKit 会把本地基础镜像误判为需从 Docker Hub 拉取而卡死；镜像层自引用堆积坑也已由 Dockerfile 的 `holo-backend-base` 解耦解决。

## 标准流程（一条命令）

```bash
HOLO_DEPLOY_CONFIRM=yes bash /Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/agent-skills/holo-backend-deploy/scripts/deploy-backend.sh
```

脚本依次做：

1. **本地测试** `npm test --prefix HoloBackend`；失败即停（`tests/prompts.test.js` 有已知 flaky 用例「恢复默认…302 偶发 500」，复跑即过；确认是它才可加 `HOLO_DEPLOY_SKIP_TESTS=1`）。
2. **提交范围守卫**：`git add -- HoloBackend` → `git commit -- HoloBackend`（pathspec 提交，暂存区里其他文件原样留下）→ 断言 HEAD 不含后端之外路径。记录发布基线 commit。
3. **推 origin**：失败只警告不阻断（GitHub 国内常年不稳，ECS 同步不依赖它）。
4. **同步到 ECS**（默认 `push` 模式）：`git push --force ssh://root@ECS/root/Holo HEAD:refs/heads/deploy-target`——推到一个非检出引用，不受 ECS 工作区脏状态影响。备选 `HOLO_DEPLOY_SYNC=rsync`（排除 node_modules / .env / deploy/.env.production / deploy/data，先 dry-run 再实跑）。
5. **ECS 端（`flock` 互斥）**：
   - 记录部署前 HEAD 与生产库存在性；
   - push 模式：校验 deploy-target == 本地 HEAD → 对每个已跟踪脏文件逐一 `git diff deploy-target -- file`（历史 rsync 残留内容等于目标版本属常态，真分歧则拒绝并要求人工核对）→ `git reset --hard deploy-target`；
   - **一致性备份**：`sqlite3 db ".backup out"`（无 sqlite3 则 python3 `Connection.backup`），再 `PRAGMA integrity_check`；失败即阻止发布，**不退回 cp 热拷贝**；
   - `RUN_GIT_PULL=0 nohup bash deploy.sh`，后台跑并轮询进度（防 SSH 空闲掐断长构建）；
   - **生产库保护断言**：部署前存在的 db 文件部署后必须仍在；
   - 本机 `/v1/health` 轮询 60s（deploy.sh 内置 curl 有启动竞态，以轮询为准；deploy.sh 非零但服务健康时只警告）。
6. **公网健康** + `release/status`，打印下一步 `verify:prod` 命令。

## 分层验收（脚本之后手动跑）

```bash
# 零 token 契约校验：health + release status + prompt meta/版本 + prompt content 关键文本
SKIP_INTENT_CASES=1 npm run verify:prod --prefix HoloBackend
# 发版含 Prompt 变更时强校验版本（取自 iOS PromptManager.promptVersions）
SKIP_INTENT_CASES=1 EXPECT_PROMPT_VERSION=<n> npm run verify:prod --prefix HoloBackend
# 必要时跑真实 intent（消耗少量 token、产生 ai_call_logs）：expense / task / health 三 case
npm run verify:prod --prefix HoloBackend
```

判定原则：以「本机 health + 公网 verify:prod 双通过」为发布完成；`/v1/prompts/:type` 在生产返回 404（仅测试模式注册），验证 Prompt 以 `verify:prod` 的 meta 校验或 ECS SQLite `prompt_versions` 最新行为准；容器内实际代码可用 `docker exec holo-backend grep ... /app/src/...` 直查。

## 失败处理

- 本地测试失败：停止，报第一处可操作错误。
- 直推 ECS 失败：检查 SSH 与 `/root/Holo` 仓库；不要改用 ECS `git pull`（GitHub 不通）。rsync 模式失败：不重建容器。
- 部署锁被占用：停止，报告已有发布在跑，不杀进程。
- 「服务器存在真正分歧的改动」：人工 `git diff deploy-target -- <file>` 看是什么；确认可丢弃才用 `HOLO_DEPLOY_FORCE_ALIGN=1`。
- 备份失败：**不发布**。查磁盘空间、sqlite3/python3 是否可用。
- `deploy.sh` 非零且服务不健康：看脚本打印的 `/tmp/holo-deploy-*.log`、`docker compose ps/logs`，不盲目重试；重跑前先核实生产是否已被另一会话更新（ECS HEAD、`docker images` 时间、容器内 grep）。
- 本机健康但公网失败：查 Nginx/域名/反代，不要判定应用发布失败。
- 生产库文件消失：**立即停止**，按记忆档 `backend-deploy-pitfalls` 坑 15 用 `/proc/<容器PID>/fd` 恢复 db/wal/shm 三件。

任何失败都要报告：失败阶段、已完成步骤、基线 commit、是否已改变生产容器。未经东林明确授权不删数据、不做破坏性回滚。

## 最终汇报（产品视角先行）

1. 产品结果：新后端是否已在线、用户可见影响。
2. 发布证据：基线 commit、同步方式与结果、备份文件名、deploy.sh 结果、本机 health、公网 health/release status、`verify:prod` 报告路径与结论、Prompt 版本。
3. 风险与后续：是否跑了真实 intent、是否还有后端改动待发、工作区是否有与本次无关的脏改。

不要把「测试通过」「代码已同步」「deploy.sh 成功」单独说成「发布完成」。

## 相关记忆档（ZCode）

`backend-deploy-pitfalls`（20 条发版实战坑：git diff 语法、rsync 残留常态、curl 竞态、PEM 内联、git clean 误删恢复链、GitHub 断连三备选路）、`backend-wrong-compose-dir-db-wipe-1019`（compose 目录用错事故）、`docker-env-no-chinese-comments`。

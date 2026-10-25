---
name: holo-backend-deploy
description: "稳定发布 HoloBackend 到阿里云 ECS：先做本地测试和版本确认，再 rsync 同步后端代码，在 ECS 上加锁、备份 SQLite 后调用项目自带的 deploy.sh 重建容器，最后用 npm run verify:prod 做本机+公网分层验收（零 token 元数据校验到真实 intent 请求）。用户说部署后端、同步服务器、SSH 发布、Docker 打包上线或后端发版时使用。"
metadata:
  short-description: "稳定发布 HoloBackend 并完成线上验收"
---

# HoloBackend 稳定发布

这是 Holo 后端的标准生产发布流程。目标是让每次发布都能回答：部署的是哪个版本、代码是否完整同步、容器是否真的使用了新代码、线上入口是否已经生效。

> 原则：能复用项目脚本就**不要**手写并行流程。`deploy/deploy.sh` 负责服务器端的构建/启动/基础健康检查，`scripts/verify-production-release.sh`（`npm run verify:prod`）负责公网验收；本 skill 只在这两个脚本之外补它们没覆盖的增强（互斥锁、SQLite 备份、轮询、分层判定）和发布规范，避免与脚本漂移。

## 固定环境

- 本地仓库：`/Users/tangyuxuan/Desktop/Claude/HOLO`
- 本地后端目录：`HoloBackend/`
- 本地脚本：`HoloBackend/scripts/`（`smoke-test.sh`、`verify-production-release.sh`）和 `HoloBackend/deploy/`（`deploy.sh`）
- ECS：`root@123.56.104.9`
- ECS 仓库：`/root/Holo`
- ECS 后端目录：`/root/Holo/HoloBackend`
- Compose 目录：`/root/Holo/HoloBackend/deploy`
- 服务和容器：`holo-backend`
- 公网入口：`https://api.holoapp.cn`

## 执行前规则

1. 先确认用户确实要求发布；只做检查或诊断时不得执行远程写操作。
2. 读取本地 Git 状态和 `origin`。只允许提交/同步 `HoloBackend/`，不能带入 iOS、文档或临时文件。
3. 检查后端变更是否包含 Prompt、路由、依赖、Docker 或配置变化；如包含，最终明确提醒"后端改动需要发版/部署后端"。
4. 不读取、打印或询问 `.env.production`、API Key、管理员密码等秘密内容。
5. 不在 ECS 上直接依赖 GitHub。代码默认由本地 rsync 同步；ECS `git pull` 仅作明确故障排查路径（见 deploy.sh 的 `RUN_GIT_PULL=1`）。

## 标准流程

### 1. 本地验证和版本锁定

在 `/Users/tangyuxuan/Desktop/Claude/HOLO` 执行：

```bash
npm test --prefix HoloBackend
git -C /Users/tangyuxuan/Desktop/Claude/HOLO status --short
git -C /Users/tangyuxuan/Desktop/Claude/HOLO remote -v
```

- 单元测试失败必须停止发布。
- 可选冒烟：本地 `npm run dev --prefix HoloBackend` 起服务后，另开终端 `npm run smoke --prefix HoloBackend`（默认打 `127.0.0.1:8787`，跑 health + 非流式/流式 chat，可选传 wav 跑 ASR）。
- 如果发版内容含 Prompt 变更，记录期望版本号（取自 iOS `PromptManager.promptVersions`），验收阶段用 `EXPECT_PROMPT_VERSION` 强校验。

如果存在后端未提交变更，按用户约定只暂存 `HoloBackend/`，使用英文前缀的 commit message。发布前记录当前 commit SHA；若执行了 commit/push，重新读取 SHA，并确认目标远端仍是 `git@github.com:Donglin5525/Holo.git`。

### 2. 代码同步

先做预览，确认不会触碰生产密钥和 SQLite：

```bash
rsync -az --delete --dry-run \
  --exclude node_modules \
  --exclude .env \
  --exclude deploy/.env.production \
  --exclude deploy/data \
  /Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/ \
  root@123.56.104.9:/root/Holo/HoloBackend/
```

确认预览只涉及后端代码后，再执行同一命令去掉 `--dry-run`。`deploy/data` 是线上 SQLite 持久化目录，永远不能被 `--delete` 处理。

### 3. ECS 部署（调用 deploy.sh + 互斥/备份增强）

通过 SSH 执行，部署过程必须互斥。锁内先做 SQLite 备份（deploy.sh 不做这步），再调用项目自带的 `deploy.sh`：

```bash
ssh root@123.56.104.9 'flock -n /tmp/holo-backend-deploy.lock bash -s' <<'REMOTE'
set -euo pipefail
cd /root/Holo/HoloBackend/deploy

# (a) 备份 SQLite —— deploy.sh 只 mkdir data，不主动备份
if [ -f data/holo-backend.db ]; then
  mkdir -p data/backups
  cp data/holo-backend.db "data/backups/holo-backend-$(date +%Y%m%d-%H%M%S).db"
fi

# (b) 检查 .env.production 存在（不输出内容）
test -f .env.production

# (c) 调用项目脚本：检查 env → DOCKER_BUILDKIT=0 build → up -d --force-recreate → 基础 health 验收
bash deploy.sh
REMOTE
```

关于 `deploy.sh`：
- 它已内置 `DOCKER_BUILDKIT=0`。**不要**绕过脚本改用 `docker compose up -d --build`——BuildKit 会把 Holo 本地基础镜像误判为需从 Docker Hub 拉取而卡死（经典踩坑）。
- 它内部用 `sleep 3` 等待启动并跑本机+公网基础健康检查（health / release status / prompts meta）。
- 应急走 GitHub：`RUN_GIT_PULL=1 bash deploy.sh`；正常发布仍优先本地 rsync。

deploy.sh 返回后，**用轮询确认本机稳定**（不要只信脚本里的固定 sleep）：

```bash
ssh root@123.56.104.9 'for i in $(seq 1 20); do
  curl -fsS http://127.0.0.1:8787/v1/health && echo && exit 0
  sleep 1
done; echo "health poll timeout"; exit 1'
```

### 4. 分层验收（先本机，再公网 verify:prod）

**先验服务器本机**（确认容器真的起来了，不是 Nginx 在兜底）：

```bash
ssh root@123.56.104.9 'curl -fsS http://127.0.0.1:8787/v1/health'
```

**再在本地 Mac 上跑公网验收脚本**（打 `https://api.holoapp.cn`）：

```bash
# 零 token 元数据/契约校验：health + release status + prompt meta + prompt content contract，不发真实 AI 请求
SKIP_INTENT_CASES=1 npm run verify:prod --prefix HoloBackend

# 发版 Prompt 时强校验版本（版本号取自 iOS PromptManager.promptVersions）
SKIP_INTENT_CASES=1 EXPECT_PROMPT_VERSION=<n> npm run verify:prod --prefix HoloBackend

# 必要时跑真实 intent 验收（消耗少量 token 并产生日志）：expense / task / health 三个 case
npm run verify:prod --prefix HoloBackend
```

`verify:prod` 会：解析每步 JSON、校验 release/service 字段、校验 Prompt meta 与版本、校验 Prompt content 含 `transactionDate,reminderDate,query_analysis` 等关键文本、可选跑三个真实 intent case，并产出一份 markdown 报告到 `$TMPDIR`。它完整覆盖（且强于）手动 `curl /v1/prompts/:type` 确认版本那一步。

验收判定原则：
- 裸 IP `:8787` 只能作**本机**依据：8787 仅绑定 ECS 本机，公网入口是 `https://api.holoapp.cn`。
- 优先做零 token 校验（`SKIP_INTENT_CASES=1`）；真实 intent 请求会产生 token 和 `/v1/admin/logs` 日志，报告中要明确区分。
- health 正常但版本/Prompt 不对：以 `/v1/release/status`、`/v1/prompts/meta` 和运行时 SQLite `prompt_versions` 为准，不能只看本地 `defaultPrompts.json`。

## 失败处理

- 本地测试失败：停止，报告第一处可操作错误。
- rsync 失败：不重建容器，检查 SSH、路径和磁盘空间。
- 部署锁被占用：停止，报告已有发布任务，不强行杀进程。
- deploy.sh 退出非零：收集 `docker compose ps`、`docker compose logs --tail=120 holo-backend` 和 deploy.sh 输出，不要盲目重试。
- 容器未健康：收集容器状态、最近日志和本机 health 响应；注意 `deploy.sh` 的 sleep 固定，必要时以第 3 步的轮询结果为准。
- verify:prod 失败：打开它产出的 markdown 报告定位失败步骤（每个 step 有 PASS/FAIL 和输出片段）。
- 本机健康但公网失败：检查 Nginx、域名和反向代理，不要判定应用代码发布失败。

任何失败都要报告失败阶段、已完成步骤、commit SHA，以及是否已经改变生产容器。除非用户明确授权，不自动删除数据、不执行 destructive rollback。

## 最终汇报

按以下顺序汇报：

1. 产品结果：新后端是否已经在线、用户可见影响是什么。
2. 发布证据：commit SHA、rsync 结果、deploy.sh 执行结果、容器状态、本机 health、`verify:prod` 报告路径与结论、Prompt/runtime 版本。
3. 风险和后续：是否跑了真实 intent 请求、是否需要后端继续部署、是否存在与本次无关的工作区脏改。

不要把"本地测试通过""代码已同步"或"deploy.sh 执行成功"单独说成"生产发布完成"——以本机 health + 公网 `verify:prod` 双通过为准。

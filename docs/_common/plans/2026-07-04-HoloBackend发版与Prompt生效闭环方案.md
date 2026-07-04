# HoloBackend 发版与 Prompt 生效闭环方案

## 产品结论

“后端已经发版”不能再只表示代码上传到 ECS 或容器重启成功。对 HOLO 来说，真正完成的定义应该是：生产域名 `https://api.holoapp.cn` 已经跑到目标代码，运行时 Prompt 已经切到目标版本，真实业务请求返回符合预期，App 端也能消费这些字段。

这件事要从工程动作升级成产品流程。每次改到 `HoloBackend`、Prompt、Router、Quota、订阅、Docker、环境配置或部署脚本，都必须产出一张发版证据单。以后如果用户觉得“发了但没生效”，先看证据单定位断在哪一层，而不是重新猜。

## 为什么会“发了但没生效”

HOLO 当前有五层真相，任何一层没对齐，用户看到的都会像“没生效”：

| 层级 | 你以为的完成 | 真实风险 | 必查证据 |
| --- | --- | --- | --- |
| 文件层 | 本地代码改了、push 了 | ECS 上仍是旧文件，或同步漏了文件 | 远端目标文件 hash / commit |
| 镜像层 | 文件到了服务器 | Docker 没重新 build，容器还跑旧镜像 | 镜像构建时间、容器启动时间 |
| 入口层 | 本机 health 正常 | App 实际走 `https://api.holoapp.cn`，不是裸 IP 或公网 `:8787` | 公网 `/v1/health` |
| Prompt 层 | `defaultPrompts.json` 改了 | 运行时优先读 SQLite 最新 `prompt_versions`，文件不一定是当前版本 | `/v1/prompts/meta`、`/v1/prompts/<type>` |
| App 契约层 | 后端返回对了 | iOS 可能读旧字段、走 fallback、命中旧构建或本地缓存 | 真机端到端用例 |

其中 Prompt 层是最容易误判的。`promptRegistry.js` 当前会优先从 SQLite 读取最新 `prompt_versions`；`defaultPrompts.json` 变化只会在服务启动时同步成新历史版本。也就是说，文件存在新规则，不等于运行时正在使用这份内容。

## 标准流程

### 1. 发布前声明目标

每次后端发版前先写清楚 4 件事：

- 本次目标：例如 `intent_recognition` 升到 v21，或 Plus quota 规则生效。
- 影响面：Prompt、Router、API、数据库、环境变量、iOS 契约。
- 真实用例：至少 1 条能证明目标生效的用户句子或 API 请求。
- 回滚点：本次发版前的 commit / Prompt version / 容器状态。

没有目标，就无法判断“到底有没有生效”。

### 2. 部署动作采用稳定路径

默认部署目标：

- 本地后端：`/Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend`
- ECS：`root@123.56.104.9`
- 远端目录：`/root/Holo/HoloBackend`
- Compose 目录：`/root/Holo/HoloBackend/deploy`
- 容器名：`holo-backend`
- 本机端口：`127.0.0.1:8787`
- 生产入口：`https://api.holoapp.cn`

推荐同步命令：

```bash
rsync -az --delete \
  --exclude node_modules \
  --exclude .env \
  --exclude deploy/.env.production \
  --exclude deploy/data \
  /Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/ \
  root@123.56.104.9:/root/Holo/HoloBackend/
```

推荐服务器重建命令：

```bash
cd /root/Holo/HoloBackend/deploy
DOCKER_BUILDKIT=0 docker compose build holo-backend
docker compose up -d --force-recreate holo-backend
```

这里明确关闭 BuildKit，是为了避免 `deploy-holo-backend:latest` 这类本地镜像被当作远端镜像拉取。不要只执行 `git pull` 或只执行 `docker compose restart`，除非本次明确是配置级重启。

### 3. 部署后四层验收

只看 `/v1/health` 不够。标准验收要串起四层：

```bash
# 服务器本机健康
ssh root@123.56.104.9 'curl -fsS http://127.0.0.1:8787/v1/health'

# App 实际公网入口健康
curl -fsS https://api.holoapp.cn/v1/health

# Prompt 运行时版本
curl -fsS https://api.holoapp.cn/v1/release/status
curl -fsS https://api.holoapp.cn/v1/prompts/meta
curl -fsS https://api.holoapp.cn/v1/prompts/intent_recognition

# 真实 intent 请求
BASE_URL=https://api.holoapp.cn \
EXPECT_PROMPT_VERSION=21 \
bash HoloBackend/scripts/verify-production-release.sh
```

`verify-production-release.sh` 会检查：

- 公网 health 是否是 `holo-ai-gateway`
- Release status 是否能返回当前服务、Prompt 摘要、路由摘要和数据库配置状态
- 指定 Prompt 是否存在
- Prompt 正文是否包含关键契约，例如 `transactionDate`、`reminderDate`、`query_analysis`
- 默认发送三条真实 intent 用例，验证是否按预期路由：记账日期、任务提醒、健康睡眠分析
- 生成一份 Markdown 证据单

注意：真实 intent 用例不会写入用户业务数据，但会调用 `/v1/ai/chat/completions`，因此可能消耗模型 token，并留下 usage / AI call log。只想做零 token 的版本/内容检查时使用：

```bash
SKIP_INTENT_CASES=1 npm run verify:prod
```

### 4. App 端契约验收

后端验收通过后，再用真机验证 3 到 5 条用户路径。每条都要确认“后端返回字段”被 App 正确消费。

建议固定为：

| 用例 | 后端证据 | App 证据 |
| --- | --- | --- |
| “昨天午饭花了35” | intent 为 `record_expense`，含 `transactionDate` | 确认卡日期正确，落库日期正确 |
| “明天早上提醒我买水” | intent 为 `create_task`，含 `reminderDate` | 待办提醒时间正确 |
| “最近状态不好，看看睡眠咋样” | intent 为 `query_analysis`，`analysisDomain=health` | HoloAI 进入健康分析链路 |
| Plus 超限 | quota API 返回可解释错误 | App 弹出对话式付费墙，购买后恢复原动作 |
| Prompt 版本刷新 | `/v1/prompts/meta` 返回新版本 | iOS 不再命中旧 fallback 或旧缓存 |

## 发版证据单模板

每次发版结束后保留以下信息：

```markdown
# HoloBackend Release Evidence

- Date:
- Operator:
- Local commit:
- Remote host:
- Remote path:
- Changed area:
- Expected behavior:
- Rollback point:

## Deployment

- rsync completed:
- docker build completed:
- container recreated:
- container started at:

## Runtime Verification

- local ECS health:
- public health:
- prompt meta:
- prompt content contract:
- real intent cases:

## App Verification

- device/build:
- account:
- user path 1:
- user path 2:
- user path 3:

## Open Risks

- not verified:
- requires follow-up:
```

## 排障决策树

如果“发了但没生效”，按这个顺序查：

1. 公网 `https://api.holoapp.cn/v1/health` 是否正常。  
   不正常：先查 Nginx、容器、端口和服务器 health。

2. `/v1/prompts/meta` 是否有目标 Prompt 版本。  
   没有：查容器是否重建、服务是否重启、SQLite `prompt_versions` 是否仍停在旧版本。

3. `/v1/release/status` 是否能返回当前服务摘要。  
   不能：说明生产容器还没有跑到支持 release status 的代码，先回查同步、构建和强制重建。

4. `/v1/prompts/<type>` 正文是否包含目标规则。  
   没有：查 `defaultPrompts.json` 是否同步到远端、`PROMPT_VERSIONS` 是否更新、数据库是否有 managed/reset 版本覆盖。

5. 真实 intent 请求是否返回目标字段。  
   没有：查系统 prompt 是否随请求传入、模型 provider 是否是预期、输出是否被截断、字段是否被 LLM 漏掉。

6. 后端返回正确但 App 不对。  
   查 iOS 是否走生产 endpoint、是否走本地 fallback、是否读取旧字段、是否卡在缓存/持久化恢复/卡片渲染层。

## 后续改造建议

P0：每次后端改动后必须跑 `verify-production-release.sh`，并把报告路径贴到交付说明里。  
P1：`deploy/deploy.sh` 默认假设代码已由 rsync / bundle 同步；如确实要 ECS 自行拉取，显式使用 `RUN_GIT_PULL=1 bash deploy.sh`。  
P1：`deploy/deploy.sh` 已去掉裸 IP 提示，并加入 `DOCKER_BUILDKIT=0`、`--force-recreate`、公网 health、release status 和 Prompt meta 验收。  
P1：给 `/v1/health` 增加 commit、buildTime、promptSummary，但不要暴露 secret。  
P2：`/v1/release/status` 已增加安全摘要，返回当前 release 环境变量、Prompt 版本、关键路由配置和数据库配置状态；不会暴露 API key、admin secret 或完整数据库路径。  
P2：iOS 调试页显示当前后端 base URL、Prompt metadata、最近一次 intent 请求命中的 Prompt version。

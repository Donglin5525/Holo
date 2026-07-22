# ECS 部署手册

这份手册用于阿里云 ECS 部署 Holo AI Gateway，含 SQLite 持久化、管理后台、安全配置。

## 推荐 ECS 规格

- 地域：华东或华北，尽量贴近你的主要用户。
- 系统：Ubuntu 22.04 LTS 或 Alibaba Cloud Linux 3。
- 规格：2 vCPU / 2GB 内存起步。
- 带宽：按流量或固定 3-5 Mbps 起步。
- 安全组：开放 `22`（SSH）、`80`（Nginx），**禁止开放 `8787`**。

## 首次安装

```bash
sudo apt update
sudo apt install -y git nginx ca-certificates curl
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
sudo apt install -y docker-compose-plugin
```

## 部署代码

```bash
git clone <你的仓库地址> Holo
cd Holo/HoloBackend/deploy
cp env.production.example .env.production
nano .env.production
```

把 `.env.production` 里的以下内容填好（不要提交这个文件）：

- `DEEPSEEK_API_KEY` — DeepSeek API Key
- `DASHSCOPE_API_KEY` — 阿里云 DashScope API Key
- `HOLO_AGENT_LOOP_REQUESTS_PER_MINUTE` / `HOLO_AGENT_LOOP_REQUESTS_PER_DAY` — 深度 Agent 内部 LLM 轮次限额
- `HOLO_ADMIN_TOKEN` — 管理后台 API Token（用于 curl 调试）
- `HOLO_ADMIN_USERNAME` / `HOLO_ADMIN_PASSWORD` — 管理后台登录凭证
- `HOLO_ADMIN_SESSION_SECRET` — 随机字符串，用于 Cookie 签名

## 创建数据目录

SQLite 数据库需要持久化到宿主机：

```bash
mkdir -p data
```

## 启动服务

```bash
cd ~/Holo/HoloBackend/deploy
docker compose up -d --build
docker compose logs -f holo-backend
```

看到以下输出说明启动成功：

```
[DB] 4 个 migration 全部完成
Holo AI Gateway listening on http://localhost:8787
```

## Nginx 反向代理

```bash
sudo cp nginx-holo-backend.conf /etc/nginx/sites-available/holo-backend
sudo ln -s /etc/nginx/sites-available/holo-backend /etc/nginx/sites-enabled/holo-backend
sudo rm -f /etc/nginx/sites-enabled/default  # 移除默认站点
sudo nginx -t
sudo systemctl reload nginx
```

验证 Nginx 代理：

```bash
curl http://127.0.0.1/v1/health
# 应返回 {"ok":true,"service":"holo-ai-gateway"}
```

## 安全组配置

在阿里云控制台 → ECS → 安全组，配置以下规则：

| 端口 | 来源 | 用途 |
|------|------|------|
| 22 | 你的 IP | SSH 管理 |
| 80 | 0.0.0.0/0 | API 端点（Nginx 代理） |
| 8787 | **不开放** | Hono 直接暴露，禁止公网访问 |

> 如果需要临时限制 API 端点只允许你的 IP（App Attest 上线前），在安全组中将 `80` 端口的来源改为你当前的公网 IP。

## 管理后台访问（SSH tunnel）

本期没有 HTTPS，管理后台不暴露公网。通过 SSH tunnel 从本地电脑访问：

```bash
# 在你的 Mac 上执行（不是 ECS 上）
ssh -L 8787:127.0.0.1:8787 root@<你的ECS公网IP>

# 然后在浏览器打开：
# http://localhost:8787/admin/logs
```

输入 `.env.production` 中配置的用户名和密码登录。

## 更新服务

推荐在本地先同步代码到服务器，保留生产密钥和持久化数据：

```bash
rsync -az --delete \
  --exclude node_modules \
  --exclude .env \
  --exclude deploy/.env.production \
  --exclude deploy/data \
  /Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/ \
  root@<你的ECS公网IP>:/root/Holo/HoloBackend/
```

然后在 ECS 上执行：

```bash
cd HoloBackend/deploy
bash deploy.sh
```

> SQLite 数据库在 `deploy/data/` 目录下，`docker compose up --build` 不会影响数据。
> 如果确实要在 ECS 上直接拉 GitHub，使用 `RUN_GIT_PULL=1 bash deploy.sh`；但线上链路不稳定时优先使用本地同步或 bundle。

## 数据库备份

```bash
# 手动备份
cp data/holo-backend.db data/holo-backend-$(date +%Y%m%d).db

# 查看备份（migration 前会自动备份到 data/backups/）
ls data/backups/
```

## 验收接口

```bash
# 健康检查
curl http://127.0.0.1:8787/v1/health

# Release 状态摘要
curl https://api.holoapp.cn/v1/release/status

# Prompt 运行时版本
curl https://api.holoapp.cn/v1/prompts/meta

# AI 对话（需要配置真实 provider）
curl -X POST http://127.0.0.1:8787/v1/ai/chat/completions \
  -H 'content-type: application/json' \
  -H 'x-holo-device-id: ecs-smoke-device' \
  -d '{"purpose":"chat","stream":false,"messages":[{"role":"user","content":"请只回复 Holo ECS OK"}]}'

# 语音转写（需要上传真实音频文件）
curl -X POST http://127.0.0.1:8787/v1/asr/transcriptions \
  -H 'x-holo-device-id: ecs-smoke-device' \
  -F 'audio=@sample.wav' \
  -F 'locale=zh-CN'
```

## 日常运维

```bash
# 查看日志
docker compose logs -f holo-backend

# 查看请求耗时日志（实时）
docker compose logs -f holo-backend | grep 'POST\|GET'

# 重启服务
docker compose restart

# 停止服务
docker compose down
```

## 生产前必须补齐

- 域名与 HTTPS 已使用 `https://api.holoapp.cn`；发布后需验证 `/v1/live`、`/v1/ready` 和真实业务请求。
- App Attest 代码闭环已实现。生产启用前需提供 Team ID、Bundle ID、production 环境与容器内可信根证书路径，并完成 TestFlight/Release 真机灰度；之后再设置 `HOLO_ENFORCE_APP_ATTEST=true`。
- 管理员 Secure Cookie 与登录失败限速已由应用层实现；公网仍建议叠加 Nginx IP allowlist 或 VPN。
- 生产同步必须排除 `deploy/.env.production*` 和 `deploy/data`，避免 `--delete` 删除配置备份或数据库。

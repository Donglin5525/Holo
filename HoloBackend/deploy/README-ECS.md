# ECS 部署手册

这份手册用于第一台阿里云 ECS，把 Holo AI Gateway 跑起来。第一阶段先用 Docker Compose，后面要加其他后端服务时也方便扩展。

## 推荐 ECS 规格

- 地域：华东或华北，尽量贴近你的主要用户。
- 系统：Ubuntu 22.04 LTS 或 Alibaba Cloud Linux 3。
- 规格：2 vCPU / 2GB 内存起步。
- 带宽：按流量或固定 3-5 Mbps 起步。
- 安全组：先开放 `22`、`80`，如果暂时没有域名和 HTTPS，也可以临时开放 `8787` 做内测。

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

把 `.env.production` 里的 `DEEPSEEK_API_KEY` 和 `DASHSCOPE_API_KEY` 填好。不要提交这个文件。

启动服务：

```bash
docker compose up -d --build
docker compose logs -f holo-backend
```

健康检查：

```bash
curl http://127.0.0.1:8787/v1/health
```

## Nginx 反向代理

```bash
sudo cp nginx-holo-backend.conf /etc/nginx/sites-available/holo-backend
sudo ln -s /etc/nginx/sites-available/holo-backend /etc/nginx/sites-enabled/holo-backend
sudo nginx -t
sudo systemctl reload nginx
```

如果还没有域名，内测可以先用：

```text
http://服务器公网IP/v1/health
```

有域名后再补 HTTPS：

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d 你的域名
```

## 更新服务

```bash
cd Holo
git pull
cd HoloBackend/deploy
docker compose up -d --build
```

## 验收接口

文本：

```bash
curl -X POST http://127.0.0.1:8787/v1/ai/chat/completions \
  -H 'content-type: application/json' \
  -H 'x-holo-device-id: ecs-smoke-device' \
  -d '{"purpose":"chat","stream":false,"messages":[{"role":"user","content":"请只回复 Holo ECS OK"}]}'
```

语音需要上传真实 wav：

```bash
curl -X POST http://127.0.0.1:8787/v1/asr/transcriptions \
  -H 'x-holo-device-id: ecs-smoke-device' \
  -F 'audio=@/path/to/sample.wav' \
  -F 'locale=zh-CN'
```

## 生产前必须补齐

- `HOLO_ENFORCE_APP_ATTEST=true` 后接真实 App Attest。
- 域名 + HTTPS。
- 更持久的限流存储，避免重启后计数清空。
- 日志轮转和基础监控。

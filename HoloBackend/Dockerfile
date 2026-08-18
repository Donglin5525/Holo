# 基础镜像固定为 holo-backend-base:latest（ECS 上压扁生成的单层 node 运行环境，服务器拉不动
# Docker Hub，不可改为远端镜像名）。构建产物标签是 deploy-holo-backend:latest，与基础镜像标签
# 解耦，避免每次发版在上一版镜像上叠层导致镜像层无限膨胀（2026-08-18 曾堆到 959 层触发
# overlay mount 参数超限）。
FROM holo-backend-base:latest AS builder

WORKDIR /app
RUN rm -rf /app/src /app/node_modules

COPY package*.json ./
RUN npm ci --omit=dev

# 阶段 2: 运行时
FROM holo-backend-base:latest

WORKDIR /app
RUN rm -rf /app/src /app/node_modules

COPY --from=builder /app/node_modules ./node_modules
COPY package*.json ./
COPY src ./src

EXPOSE 8787

CMD ["node", "src/server.js"]

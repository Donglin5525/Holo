# 阶段 1: 基于 ECS 已有镜像编译原生模块
FROM deploy-holo-backend:latest AS builder

WORKDIR /app
RUN rm -rf /app/src /app/node_modules

COPY package*.json ./
RUN npm ci --omit=dev

# 阶段 2: 运行时
FROM deploy-holo-backend:latest

WORKDIR /app
RUN rm -rf /app/src /app/node_modules

COPY --from=builder /app/node_modules ./node_modules
COPY package*.json ./
COPY src ./src

EXPOSE 8787

CMD ["node", "src/server.js"]

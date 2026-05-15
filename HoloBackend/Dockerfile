FROM node:24-alpine

WORKDIR /app

ENV NODE_ENV=production

# better-sqlite3 编译依赖
RUN apk add --no-cache build-base python3

COPY package*.json ./
RUN npm ci --omit=dev

COPY src ./src

EXPOSE 8787

CMD ["node", "src/server.js"]

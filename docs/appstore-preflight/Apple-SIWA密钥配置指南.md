# Apple Sign in with Apple 密钥配置（账号撤销闭环）

> 交给 GPT 执行的自包含操作文档。生成于 2026-08-14。

## 背景（为什么做）

Holo iOS App 支持「通过 Apple 登录」。App Store 审核条款要求：用户在 App 内删除账号时，开发者必须同时撤销其 Apple 登录凭证。

现状：
- 客户端：删除账号流程已实现——删号前先调后端 `POST /v1/auth/apple/revoke`（`AppleSignInAuthService.markAccountDeleted()`）
- 后端：撤销服务已上线（`HoloBackend/src/auth/appleRevokeService.js`，生产环境 ECS `root@123.56.104.9`，目录 `/root/Holo/HoloBackend/deploy`）
- **缺的只有 Apple 签发的 .p8 密钥**。未配置时后端 revoke 返回 `APPLE_REVOKE_NOT_CONFIGURED`，客户端删号继续走（best-effort），但 Apple 侧凭证没撤销，构成审核风险。

## 需要写入的环境变量

后端读取（见 `HoloBackend/src/config.js`）：

| 变量 | 值 |
|---|---|
| `APPLE_TEAM_ID` | `6WZ5TXGPQY`（代码已有默认值，可不写） |
| `APPLE_KEY_ID` | 新建 Key 的 10 位 ID（步骤 3 获得） |
| `APPLE_PRIVATE_KEY_PEM` | .p8 文件内容整段（步骤 3 下载） |
| `APPLE_REVOKE_CLIENT_ID` | 默认 `com.tangyuxuan.holo-app`，不用写 |

## 步骤

1. 登录 Apple Developer（https://developer.apple.com）→ **Certificates, Identifiers & Profiles** → **Keys** → 点 **+** 新建。
2. 名称填 `Holo SIWA Revoke`，勾选 **Sign in with Apple** → 点 **Configure**，Primary App ID 选 `com.tangyuxuan.holo-app` → Continue → Register。
3. **记下 Key ID**（10 位字符），然后下载 .p8 文件。
   ⚠️ **.p8 只能下载一次**，丢失只能吊销重建。存到安全位置，**绝不进 git / 不发聊天工具**。
4. SSH 到服务器：`ssh root@123.56.104.9`，编辑 `/root/Holo/HoloBackend/deploy/.env.production`，追加两行（值写成**单行**，PEM 的换行用字面 `\n` 两个字符表示，后端 `normalizePem` 会转换）：

   ```
   APPLE_KEY_ID=你的10位KeyID
   APPLE_PRIVATE_KEY_PEM=-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMG...\n-----END PRIVATE KEY-----
   ```

   ⚠️ 这个 .env 文件**不能写中文注释、不能有全角字符**，否则解析器报错且容器会静默用旧配置启动（表面健康、实际没生效，很隐蔽）。
5. 重启后端：`cd /root/Holo/HoloBackend/deploy && docker compose up -d holo-backend`。
6. 验证：
   - 容器健康：`docker compose ps` 显示 healthy
   - 功能验证：真机 App 用 Apple 账号登录 → 设置 → 删除账号 → 后端日志 `docker logs <容器名> --tail 50` 里 revoke 请求返回 200，**没有** `APPLE_REVOKE_NOT_CONFIGURED`
   - 事后可到 Apple ID 隐私页确认该 App 的登录已撤销

## 回归确认

配置后无需发版（纯环境变量），重启容器即生效。若 `APPLE_PRIVATE_KEY_PEM` 写错（换行没转好），revoke 会报 JWT 解析错误——检查 `\n` 是否为字面两字符。

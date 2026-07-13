# Holo 上线敏感信息收口与内部真机日志设计

**日期：** 2026-07-13

**状态：** 待书面规格确认

**范围：** Holo iOS、HoloBackend、生产部署与验收

## 1. 产品结论

Holo 正式版不向任何普通用户或 Plus 用户暴露模型服务商、模型名称、温度、Token 上限、API Key、Prompt 正文、路由配置、灰度开关、调试入口和原始 LLM 日志。

东林作为内部负责人，可以在 App Store 正式版真机中查看完整 AI 调用日志，但必须先通过 Apple 登录完成后端身份验证。内部日志能力是独立的运维权限，不属于 Plus 权益，也不允许通过客户端本地开关、隐藏手势或静态白名单获得。

## 2. 成功标准

1. 普通用户和 Plus 用户无法从正式版 UI、Core Data、iCloud、公开后端接口获取内部 AI 配置或完整 Prompt。
2. 非内部账号不会生成、持久化或同步完整 LLM 请求日志。
3. 东林用已授权 Apple 账号登录后，可以在真机长按 AI 回复查看对应调用的完整日志。
4. 内部权限退出登录、Apple 凭证失效或令牌过期后立即失效。
5. Prompt 由后端根据 `purpose` 选择并注入，iOS 正式版不下载托管 Prompt 正文。
6. 生产公开接口只返回实现业务所需的最小信息。
7. 所有后端变更部署到 ECS，并通过本机、服务器本机和公网三层验收。

## 3. 不采用的方案

### 3.1 隐藏手势或本地 PIN

判断逻辑和凭证会进入安装包，可被逆向或篡改，不能证明使用者是东林。

### 3.2 在 iOS 中写 Apple 用户标识白名单

白名单本身会进入安装包，且纯客户端判断可以被绕过。Apple 用户标识只能作为后端验证后的授权依据。

### 3.3 仅对 TestFlight 开放

无法覆盖 App Store 正式版本的真实线上问题，不满足东林的真机排障需求。

## 4. 身份与权限设计

### 4.1 Apple 登录交换

iOS 在 Apple 登录成功时，将 Apple 返回的 `identityToken` 和 `authorizationCode` 发送到 HoloBackend 的 `POST /v1/auth/apple/session`。

后端必须验证：

- JWT 签名来自 Apple 公钥；
- `iss` 为 Apple；
- `aud` 属于 Holo 配置允许的 Client ID；
- `exp`、`iat` 有效；
- `sub` 与验证后的 Apple 身份一致。

验证失败统一返回用户安全错误，不回传 JWT、Apple subject、密钥或验证细节。

### 4.2 内部白名单

后端环境变量保存允许使用内部诊断的 Apple `sub` 集合。白名单不进入代码仓库、iOS 安装包或公开接口。

首个内部账号通过以下受控流程登记：

1. Debug 构建完成一次 Apple 登录；
2. Debug 控制台只输出经过截断的 subject 指纹；
3. 通过本机 Keychain 中已保存的完整 `userIdentifier` 人工写入 ECS 环境变量；
4. 重建后端容器；
5. 东林重新登录验证内部权限。

不得采用“第一个登录用户自动成为管理员”的自动认领逻辑。

### 4.3 Holo 会话令牌

后端验证 Apple 身份后签发短期 Holo 会话令牌，声明至少包含：

- `sub`：内部不可读的用户标识；
- `internalDiagnostics`：是否允许内部诊断；
- `iat`、`exp`、`iss`、`aud`。

令牌使用服务端环境密钥签名，iOS 存入 Keychain。iOS 不将令牌、Apple subject 或权限声明写入 UserDefaults、Core Data、日志和剪贴板。

权限默认拒绝：网络失败、令牌过期、解析失败、退出登录、Apple 凭证撤销时，立即隐藏内部日志入口并清除内部会话。

## 5. 正式版 UI 收口

### 5.1 AI 授权页面

新增正式用户专用的 AI 数据处理授权页，只展示：

- AI 数据处理说明；
- 授权开关；
- 隐私政策入口；
- 关闭授权后的功能影响。

聊天未授权提示和本周观察卡片统一打开该页面，不再打开 `AISettingsView`。

### 5.2 开发者 AI 设置

以下功能仅在 `#if DEBUG` 中编译和访问：

- 服务商、API Key、Base URL、模型；
- 温度、最大 Token；
- Prompt 编辑、测试、刷新；
- Agent 灰度和 Mock 调试；
- 语音服务商与模型配置；
- 健康原始诊断和测试数据入口。

内部诊断权限只开放“查看调用日志”，不开放上述开发配置。

### 5.3 关于页面

版本号从 Bundle 的 `CFBundleShortVersionString` 和 `CFBundleVersion` 读取，不再硬编码。

## 6. 内部真机日志

### 6.1 普通用户路径

普通用户的 AI 回复不显示“查看日志”。iOS 不为其构造或保存完整 `LLMLog`，不写入 `rawLogJSON`，也不把完整系统 Prompt、用户上下文或原始模型响应同步到 CloudKit。

业务展示所需的结构化字段继续保留，但必须与调试日志分离，只保存渲染卡片所需的最小数据。

### 6.2 内部用户路径

后端为每次 AI 请求生成不可预测的 `requestId`。iOS 仅在内部权限有效时，将 `requestId` 与对应聊天消息 ID 做本机映射。

长按 AI 回复时：

1. iOS 检查内部权限；
2. 使用 Holo 会话令牌请求 `GET /v1/internal/ai-logs/:requestId`；
3. 后端再次验证 `internalDiagnostics`；
4. 返回该请求的完整诊断日志；
5. iOS 在现有日志页展示，支持复制。

任何普通令牌、Plus 状态、设备 ID 或客户端开关都不能访问该接口。

### 6.3 日志保留与本地存储

- 完整日志保存在后端现有受控日志存储中，沿用后台配置的清理周期；
- iOS 不把完整日志写入 Core Data 或 CloudKit；
- iOS 只在页面打开期间持有完整日志；
- 本机仅保存 `messageId → requestId` 映射，放在本地独立诊断存储中，默认保留 7 天；
- 映射不包含 Prompt、用户正文、模型响应或 Apple 身份；
- 退出登录和清除缓存时删除全部内部映射。

### 6.4 防越权

内部日志接口同时校验：

- Holo 会话令牌有效；
- `internalDiagnostics == true`；
- `requestId` 存在且处于保留期；
- 返回数据经过大小限制，避免超大响应。

访问成功和失败都记录安全审计事件，但不在审计事件中重复保存完整 Prompt 和用户正文。

## 7. Prompt 服务端化

### 7.1 请求契约

iOS 继续发送业务 `purpose`、用户消息和必要的结构化上下文，但不再发送由客户端加载的托管 Prompt。后端根据 `purpose` 查找对应 Prompt，并在调用模型前注入。

后端拒绝客户端传入模型、Provider、API Key、Base URL，以及冒充托管 Prompt 的路由字段。客户端上下文与服务端系统 Prompt 使用独立字段和固定拼装顺序，避免用户输入覆盖系统规则。

### 7.2 iOS 后备策略

正式版 AI 功能依赖在线后端，本地完整 Prompt 不提供离线业务价值。因此 Release 不携带商业 Prompt 正文；Prompt 不可用时返回功能暂不可用的用户提示，不回退到本地完整模板。

Debug 构建可以保留本地测试模板，但必须通过编译条件与 Release 隔离。

### 7.3 后端接口

- 删除或限制公网 `GET /v1/prompts`；
- 删除或限制公网 `GET /v1/prompts/:type`；
- 客户端不再调用 `GET /v1/prompts/meta`；
- Prompt 管理继续保留在现有管理员鉴权页面；
- Prompt 版本只通过管理端和部署验收工具查询。

## 8. 公网运行状态收缩

`GET /v1/health` 只返回最小可用状态。

公网 `GET /v1/release/status` 不再返回：

- Provider、模型；
- 温度、最大 Token、请求限制；
- Prompt 类型、版本和来源；
- 数据库配置状态；
- 内部路由表。

部署验收需要的完整状态迁入管理员鉴权接口。`verify:prod` 使用管理员凭证读取，凭证仅来自环境变量，不写入脚本默认值或仓库。

## 9. 用户错误与日志脱敏

iOS 建立统一 AI 用户错误映射。界面只展示网络不可用、服务繁忙、请求超时、授权失效、次数达到上限等产品文案，不直接展示任意 `localizedDescription`。

技术错误继续使用 `Logger` 记录，但禁止输出：

- API Key、Holo 会话令牌、Apple identity token；
- Apple subject 全文；
- 完整 Prompt；
- 完整用户上下文；
- 原始 Authorization Header。

## 10. 数据迁移

首次启动新版本时执行一次幂等清理：

1. 清除现有 `ChatMessage.rawLogJSON`；
2. 保留业务卡片仍依赖的结构化数据，不盲目清除 `analysisContextJSON`；
3. 删除旧的用户自带 AI Key 和语音 Keychain 配置；
4. 清除旧 Prompt 自定义内容和缓存；
5. 不删除聊天正文、AI 记忆和业务记录。

迁移失败不阻塞 App 启动，但必须记录不含敏感正文的错误，并在后续启动重试。

## 11. 测试与验收

### 11.1 iOS 自动测试

- 普通账号不显示日志菜单；
- Plus 账号不显示日志菜单；
- 内部权限有效时显示日志菜单；
- 令牌过期、退出登录、Apple 凭证撤销后入口消失；
- 普通用户消息不写入 `rawLogJSON`；
- 历史 `rawLogJSON` 迁移后为空；
- AI 未授权入口只打开正式授权页；
- Release 不包含开发者 AI 设置入口；
- 用户错误不泄露 Provider、模型、URL、HTTP 原文。

### 11.2 后端自动测试

- Apple JWT 签名、issuer、audience、expiry 和 subject 验证；
- 非白名单 Apple 账号得到普通会话；
- 白名单账号得到内部诊断权限；
- 普通、Plus、过期和伪造令牌访问内部日志均返回 401/403；
- Prompt 由后端按 `purpose` 注入；
- 公网 Prompt 正文接口不可访问；
- 公网 release status 不含模型、温度、Token、Prompt 和路由；
- 管理员验收接口仍可提供部署证明；
- 响应和日志不包含服务端密钥。

### 11.3 Release 与生产验收

1. 运行后端全部测试；
2. 运行 iOS standalone/targeted tests；
3. 执行 iOS Release generic Simulator 构建；
4. 扫描 Release 产物中的开发设置、Provider 名称、Prompt 编辑文案和完整 Prompt 特征；
5. 部署 HoloBackend 到 ECS；
6. 验证公网 Prompt 正文接口关闭；
7. 验证公网 release status 已最小化；
8. 普通 Apple 账号真机验证无日志入口；
9. 东林账号真机验证可查看一次真实 AI 请求日志；
10. 退出登录后再次验证入口消失。

## 12. 发布与回滚

后端先以兼容模式部署：支持新服务端 Prompt 契约，同时暂时兼容旧客户端业务请求，但不再公开 Prompt 正文。iOS 新版验证通过后，再删除旧契约兼容代码。

内部权限默认关闭。若 Apple 身份验证或日志接口异常，普通 AI 功能继续可用，仅内部日志入口不可用。不得通过重新开放公网 Prompt 或公共日志接口回滚。

本轮修改涉及 `HoloBackend/`，必须完成 ECS 部署、容器重建和生产接口验收后才算交付完成。

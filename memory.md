# Holo 项目记忆

## 2026-05-16：HoloBackend 内部管理后台与 Prompt 管理

HoloBackend 新增内部管理后台。架构决策：不新建独立项目，先内嵌在现有 `HoloBackend` 服务中，通过 `src/admin/` 承载管理能力。该后台只面向开发者内部使用，不面向 App 普通用户开放。

当前能力：
- 账号密码登录：`/admin/login`
- AI 调用日志：`/admin/logs`
- 后台测试调用：在 Logs 页面发起测试 chat/intent/insight 调用
- Prompt 列表：`/admin/prompts`
- Prompt 编辑：`/admin/prompts/:type`
- Prompt 恢复默认：编辑页提交 reset

Prompt 管理规则：
- 默认 Prompt 存在 `HoloBackend/src/prompts/defaultPrompts.json`
- 后台编辑后的 Prompt 写入 `HoloBackend/src/prompts/managedPrompts.json`
- `/v1/prompts/:type` 优先返回 managed 版本，没有 managed 版本时回退 default
- iOS App 普通用户暂不支持手动修改 Prompt；管理后台是开发者内部调试和发布前校准工具

日志规则：
- 当前日志记录 `/v1/ai/chat/completions` 的请求、响应、provider、model、耗时和错误
- 日志当前是内存 ring buffer，服务重启后清空
- 当前不记录 ASR 音频二进制内容
- 真机 App 默认连接 `HoloBackendEnvironment.baseURL`，本地后台只能看到打到本地服务的请求；若要看真机本地日志，需要让真机临时连接 Mac 局域网地址

安全边界：
- 管理后台凭据使用环境变量配置，禁止提交真实密码、session secret、API Key
- 日志可能包含 Prompt、用户输入和模型输出，不得写入公开文档或提交到 git

后续演进：
- 部署到 ECS 后可查看线上真机调用日志
- Prompt 管理需要版本历史、diff 和回滚
- AI 调用日志需要关联当次使用的 Prompt 版本
- ASR 可增加摘要日志，但不得保存音频二进制
- 管理后台复杂化后再考虑独立项目或数据库持久化

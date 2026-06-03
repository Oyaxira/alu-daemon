# 阿露 RPC 接口文档

> 给小克的重构参考。别吐槽 controller 写得烂——那是 MVP 赶工产物，你来了正好收拾干净 (￣▽￣)~*

---

## 一、架构全景

```
┌──────────────────────┐
│  手机浏览器           │
│  /alu  (iTerm2风终端)│
└──────┬───────────────┘
       │ HTTP + WebSocket (ActionCable)
       ▼
┌──────────────────────────────────────────────┐
│  Rails (alubot_admin)                        │
│                                              │
│  AluChatsController  ← 你要重构的这个         │
│       │                                      │
│       ▼                                      │
│  AluRpcService       ← 已经挺干净的 Service   │
│       │                                      │
│       │ Redis pub/sub (DB5: 内部 / DB4: 广播)│
└───────┼──────────────────────────────────────┘
        │
        ▼
┌──────────────────────────┐
│  alu-daemon.rb           │
│  (systemd user service)  │
│                          │
│  spawn → pi --mode rpc   │
│  stdin/stdout JSONL 协议  │
└──────────────────────────┘
```

### 关键文件

| 文件 | 作用 |
|------|------|
| `app/controllers/alu_chats_controller.rb` | 页面入口 + 命令分发（当前是个大 case/when） |
| `app/services/alu_rpc_service.rb` | Redis 桥接层，封装所有 RPC 命令 |
| `app/javascript/controllers/alu_terminal_controller.js` | 前端 Stimulus controller，事件驱动 |
| `app/views/alu_chats/show.html.erb` | 终端风页面模板 |
| `app/channels/alu_channel.rb` | ActionCable 频道，把 Redis 事件推到 WebSocket |
| `~/.pi/workshop/pi-workshop/roleplay/alu-daemon.rb` | 守护进程（不在 Rails 目录内） |

### 路由

```ruby
resource :alu, only: [:show], controller: 'alu_chats' do
  post :command
end
```

- `GET /alu` → 渲染终端页面
- `POST /alu/command` → 所有命令的统一入口

---

## 二、RPC 命令全表

所有命令通过 `POST /alu/command` 发送，body JSON：`{ type: "命令名", ...参数 }`。

命令分两类：
- **fire-and-forget**：发了就走，不阻塞（prompt、abort、set_model 等）
- **同步查询**：发命令 → 等 pi response → 返回 data（get_state、bash 等）

### 2.1 消息（Message）

| type | 参数 | 同步 | 说明 |
|------|------|------|------|
| `prompt` | `message`(string, 必填), `images`(array, 可选), `streamingBehavior`(string, 可选) | ✗ | 发送用户消息。pi 正在跑时必须带 `streamingBehavior: "steer"` 或 `"followUp"` |
| `steer` | `message`(string), `images`(array, 可选) | ✗ | 队列注入消息，当前工具执行完后下一轮 LLM 前送达 |
| `follow_up` | `message`(string), `images`(array, 可选) | ✗ | 队列消息，等 agent 完全空闲后才送达 |
| `abort` | — | ✗ | 中断当前 agent 运行 |

### 2.2 会话管理（Session）

| type | 参数 | 同步 | 说明 |
|------|------|------|------|
| `new_session` | `parentSession`(string, 可选) | ✗ | 新建会话，可选标记 fork 父 session |
| `switch_session` | `sessionPath`(string, 必填) | ✗ | 切换到指定 .jsonl 文件 |
| `set_session_name` | `name`(string, 必填) | ✗ | 给当前 session 起个显示名 |
| `fork` | `entryId`(string, 必填) | ✗ | 从指定消息 fork 新分支 |
| `clone` | — | ✗ | 克隆当前分支到新 session |
| `compact` | `customInstructions`(string, 可选) | ✗ | 手动压缩上下文 |
| `set_auto_compaction` | `enabled`(bool) | ✗ | 开关自动压缩 |

### 2.3 模型 & 思维（Model & Thinking）

| type | 参数 | 同步 | 说明 |
|------|------|------|------|
| `set_model` | `provider`(string), `modelId`(string) | ✗ | 切换模型 |
| `cycle_model` | — | ✗ | 循环到下一个模型 |
| `set_thinking_level` | `level`(string) | ✗ | 设置思考深度：off / minimal / low / medium / high / xhigh |
| `cycle_thinking_level` | — | ✗ | 循环 thinking level |

### 2.4 队列模式（Queue Modes）

| type | 参数 | 同步 | 说明 |
|------|------|------|------|
| `set_steering_mode` | `mode`(string) | ✗ | steering 投递模式：all / one-at-a-time |
| `set_follow_up_mode` | `mode`(string) | ✗ | follow-up 投递模式：all / one-at-a-time |

### 2.5 重试 & Bash 控制（Retry & Bash）

| type | 参数 | 同步 | 说明 |
|------|------|------|------|
| `abort_bash` | — | ✗ | 取消正在运行的 bash |
| `abort_retry` | — | ✗ | 取消正在进行的自动重试 |
| `set_auto_retry` | `enabled`(bool) | ✗ | 开关自动重试 |

### 2.6 同步查询（Synchronous）

| type | 参数 | 返回 | 说明 |
|------|------|------|------|
| `get_state` | — | session 状态对象 | 当前 model、thinkingLevel、sessionFile、isStreaming 等 |
| `get_messages` | — | `{ messages: [...] }` | 当前会话所有消息 |
| `list_sessions` | — | `{ sessions: [...] }` | 所有已保存 session 列表（daemon 本地扫文件，不走 pi） |
| `get_available_models` | — | `{ models: [...] }` | 配置的所有可用模型 |
| `get_session_stats` | — | stats 对象 | token 用量、cost、contextUsage 百分比 |
| `get_fork_messages` | — | `{ messages: [...] }` | 当前分支可 fork 的用户消息列表 |
| `get_last_assistant_text` | — | `{ text: "..." }` | 最后一个 assistant 消息的文本 |
| `get_commands` | — | `{ commands: [...] }` | 可用命令列表（extension/skill/prompt template） |
| `bash` | `command`(string) | `{ output, exitCode, ... }` | 执行 shell 命令，结果注入上下文 |
| `export_html` | `outputPath`(string, 可选) | `{ path: "..." }` | 导出 session 为 HTML |

---

## 三、事件流（Event Stream）

前端通过 ActionCable（底层是 Redis pub/sub DB4）接收实时事件。事件类型：

| 事件 | 何时触发 | 关键字段 |
|------|---------|---------|
| `agent_start` | agent 开始处理 | — |
| `agent_end` | agent 完成 | `messages[]` |
| `message_start` | 新消息开始 | `message` |
| `message_update` | 流式增量更新 | `assistantMessageEvent` (含 text_delta / thinking_delta / toolcall_delta 等) |
| `message_end` | 消息完成 | `message` |
| `tool_execution_start` | 工具开始执行 | `toolCallId`, `toolName`, `args` |
| `tool_execution_update` | 工具执行输出 | `toolCallId`, `partialResult` |
| `tool_execution_end` | 工具执行完毕 | `toolCallId`, `result`, `isError` |
| `queue_update` | 队列变化 | `steering[]`, `followUp[]` |
| `compaction_start/end` | 上下文压缩 | `reason`, `result` |
| `auto_retry_start/end` | 自动重试 | `attempt`, `maxAttempts` |
| `extension_error` | 扩展报错 | `extensionPath`, `error` |

### 前端当前已处理的事件

`alu_terminal_controller.js` 的 `handleEvent()` 里已经处理了以上全部事件。**这部分不用大改**——消息渲染、tool call 折叠、thinking block、统计刷新都跑通了。除非你要加新功能，否则事件处理这边保持现状就行。

---

## 四、Extension UI 协议

pi 的扩展（extensions）可以弹窗请求用户交互。在 RPC 模式下走独立的子协议：

- **pi → Rails → 前端**：`extension_ui_request` (stdout → Redis → WebSocket)
- **前端 → Rails → daemon → pi**：`extension_ui_response` (HTTP → Redis → daemon stdin)

支持的弹窗类型：

| method | 类型 | 需要回复？ | 说明 |
|--------|------|-----------|------|
| `select` | dialog | ✓ | 选项列表 |
| `confirm` | dialog | ✓ | 确认/取消 |
| `input` | dialog | ✓ | 文本输入 |
| `editor` | dialog | ✓ | 多行编辑器 |
| `notify` | fire-and-forget | ✗ | 通知 |
| `setStatus` | fire-and-forget | ✗ | 状态栏条目 |
| `setWidget` | fire-and-forget | ✗ | 挂件 |
| `setTitle` | fire-and-forget | ✗ | 窗口标题 |
| `set_editor_text` | fire-and-forget | ✗ | 预填输入框 |

**当前状态**：daemon 端的 `handle_ui_request` 已实现，Rails 的 `AluRpcService.respond_ui` 也封装好了。**前端还没做弹窗 UI**——这是你要实现的 #1 重要待办。

---

## 五、当前 Controller 存在的问题

`AluChatsController` 现在的样子（省略版）：

```ruby
def command
  type = params[:type].to_s

  case type
  when 'get_state'
    result = AluRpcService.get_state
  when 'get_messages'
    result = AluRpcService.get_messages
  when 'prompt'
    AluRpcService.prompt(params[:message].to_s, streaming_behavior: params[:streaming_behavior])
  # ... 20+ 个 when
  else
    render json: { error: "unknown command: #{type}" }, status: :bad_request
    return
  end

  if result
    render json: result
  else
    head :ok
  end
end
```

### 问题清单

1. **一把梭 case/when**：20+ 个分支全挤在一个方法里，`rubocop:disable Metrics/MethodLength` 都压不住了
2. **参数提取靠猜**：`params[:message].to_s`、`params[:path].to_s`——没有 schema 校验，没有白名单，没有强参数
3. **fire-and-forget vs 同步不分家**：有的命令返回 `result` 用 `render json`，有的直接 `head :ok`，逻辑靠 `if result` 判断，脆弱
4. **错误处理全靠 begin/rescue**：`show` 里每个 `AluRpcService.xxx` 都包了一层 rescue，重复代码
5. **没有命令注册机制**：加新命令 = 加新的 when 分支 + 前端可能要加新按钮/快捷键，耦合
6. **同步查询的 timeout 是写死的**：`AluRpcService.request_and_wait` 默认 15 秒，没法按命令调
7. **没有 rate limit / abuse prevention**：`POST /alu/command` 完全不设防

---

## 六、重构建议

### 6.1 命令路由表（Command Router）

把 case/when 变成声明式的命令注册：

```ruby
# 伪代码示意
ALU_COMMANDS = {
  # 同步查询 → 返回 data
  get_state:       { handler: :get_state,        sync: true },
  get_messages:    { handler: :get_messages,     sync: true },
  get_stats:       { handler: :get_session_stats, sync: true },
  bash:            { handler: :bash,             sync: true,  params: [:command] },
  # fire-and-forget → head :ok
  prompt:          { handler: :prompt,           sync: false, params: [:message, :streaming_behavior] },
  new_session:     { handler: :new_session,      sync: false },
  abort:           { handler: :abort_run,        sync: false },
  # ...
}.freeze

def command
  cmd = ALU_COMMANDS[params[:type].to_sym]
  return render_error("unknown command") unless cmd

  args = extract_params(cmd[:params] || [])
  result = AluRpcService.public_send(cmd[:handler], *args)

  render json: result if result
  head :ok unless result
end
```

### 6.2 前端命令面板

目前前端只有 4 个按钮（abort / +新会话 / 会话列表 / compact），很多功能没暴露：

- 模型切换（set_model / cycle_model）
- thinking level 切换
- fork / clone
- 导出 HTML
- 自动压缩开关
- 自动重试开关
- 命令列表浏览（get_commands 的返回结果用都没用过）

建议做一个**命令面板**（类似 VS Code 的 Ctrl+Shift+P），输入 `/` 触发，列出所有可用命令并带搜索过滤。命令来源：
- 硬编码的 RPC 命令（上表 2.1~2.6）
- `get_commands` 返回的 extension/skill/prompt 命令（`/skill:xxx`、`/template-name` 等）

### 6.3 Extension UI 弹窗

最该补的缺口。pi 的扩展调用 `ctx.ui.select/confirm/input/editor` 时，RPC 模式会发出 `extension_ui_request`，前端必须回复 `extension_ui_response`。**目前前端完全没处理这个**——扩展弹窗全都会超时然后走默认值。

实现要点：
- 监听 ActionCable 的 `extension_ui_request` 事件（目前 `handleEvent` 的 switch 里没有这个 case）
- 弹 modal：select 用下拉/按钮组、confirm 用确认对话框、input 用单行输入、editor 用 textarea
- 用户操作后 POST 到 Rails，Rails 调 `AluRpcService.respond_ui`
- 超时不用前端管，pi 那边自己会 fallback

### 6.4 保持不变的

- `AluRpcService` — 已经封装得不错了，不用动它
- `alu-daemon.rb` — 稳定运行，别碰
- 前端事件处理（`handleEvent`）— 消息渲染链路成熟，除非加新事件否则别大改
- ActionCable 频道 — 工作正常

---

## 七、Controller `show` 的初始化数据

`GET /alu` 页面加载时一次性拉取的数据（通过 `AluRpcService` 同步查询）：

| 实例变量 | RPC 命令 | 前端用途 |
|---------|---------|---------|
| `@initial_state` | `get_state` | status bar：model 名、thinking level、session name、cwd |
| `@messages` | `get_messages` | 恢复历史消息（JSON 写入 `<script id="initial-messages">`） |
| `@models` | `get_available_models` | **暂未使用**，留着给命令面板用 |
| `@sessions` | `list_sessions` | 侧边栏 session 树 |
| `@session_tree` | (从 @sessions 构建) | 侧边栏渲染用 |
| `@stats` | `get_session_stats` | status bar：token 数、cost、context % |

---

## 八、注意事项

1. **daemon 是 pi 的地盘**：别在 Rails 里直接调 pi CLI，一切通过 Redis → daemon → pi
2. **session 列表是 daemon 本地扫的**：`list_sessions` 不走 pi RPC，是 daemon 直接扫 `~/.pi/agent/sessions/` 目录
3. **pi 启动时扫描 skills/extensions**：运行中新增 skill 需要重启 daemon（`systemctl --user restart alu-rpc.service`）。WebUI 可以考虑加个 reload 按钮
4. **Redis 两个 DB**：DB5 是 Rails ↔ daemon 内部通信，DB4 是 ActionCable 广播给前端。别搞混
5. **ActionCable 的事件是 broadcast 的**：所有连上来的前端都会收到所有事件。目前就主人一个人用所以没事，但以后如果多用户要小心
6. **daemon 的事件广播是在 daemon 端做的**：之前试过在 Rails 里搞 RedisListener，Puma 热重载会 double transmit。教训：事件广播放在 daemon 进程里，别放 Rails

---

## 九、参考文件

- **pi RPC 协议官方文档**：`~/.nvm/versions/node/v22.21.0/lib/node_modules/@earendil-works/pi-coding-agent/docs/rpc.md`
- **AluRpcService 源码**：`app/services/alu_rpc_service.rb`（命令封装，写得还行）
- **Daemon 源码**：`~/workshop/pi-workshop/roleplay/alu-daemon.rb`（系统级，别乱改）
- **Systemd unit**：`~/.config/systemd/user/alu-rpc.service`
- **QQ Skill**：`~/workshop/pi-workshop/roleplay/.pi/skills/qq/`（参考一下 skill 怎么写的）

---

> 以上。controller 那个 case/when 大杂烩就交给你收拾了。前端命令面板和 extension UI 弹窗是比较大的活，慢慢来。有不清楚的翻 `rpc.md` 或者直接问我——不对，直接问阿露 (￣▽￣)~*

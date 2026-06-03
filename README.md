# alu-daemon

阿露 RPC 守护进程。管理 `pi --mode rpc` 子进程，通过 Redis pub/sub 对外暴露。

## 架构

```
Rails ←→ Redis pub/sub ←→ alu-daemon ←→ pi --mode rpc
                                ↓
                         ActionCable WebSocket
                                ↓
                            浏览器前端
```

## 部署

```bash
cp systemd/alu-rpc.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user restart alu-rpc.service
```

## 依赖

- Ruby 3.1+
- `pi` CLI（npm i -g @earendil-works/pi-coding-agent）
- Redis

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ROLEPLAY_DIR` | `../pi-workshop/roleplay` | pi 角色扮演配置目录 |
| `ALU_REDIS_URL` | `redis://localhost:6379/5` | Rails ↔ daemon 内部通信 |
| `ALU_BROADCAST_REDIS_URL` | `redis://localhost:6379/4` | ActionCable 前端广播 |

## 协议文档

见 [docs/rpc-protocol.md](docs/rpc-protocol.md)

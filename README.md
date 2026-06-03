# alu-daemon

阿露 RPC 守护进程。自用，备份，别看了。

## 干嘛的

起个 `pi --mode rpc`，挂 Redis 上，让 Rails 那边能调。

## 怎么跑

```bash
cp systemd/alu-rpc.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user restart alu-rpc.service
```

完。

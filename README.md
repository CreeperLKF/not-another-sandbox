# not-another-sandbox

> **不是又一个沙箱，而是面向终端协作的有人值守权限委托机制**

一套让 AI Agent 在人类监督下临时获得提权的系统——不是困住 Agent，而是让人类全程可见、随时可停。

## 核心理念

- **授权之前**：和操作系统一样的安全（Agent 在低权限账户运行）
- **授权之后**：和用户一样的权力（完整会话访问，无命令白名单）
- **简单到眼睛**：清晰的设计，易于理解和审计

## 快速开始

### 安装

```bash
# 下载并运行安装向导
git clone https://github.com/CreeperLKF/not-another-sandbox.git
cd not-another-sandbox
make build
sudo ./bin/nas-setup
```

安装向导将引导你：
1. 选择模式（direct/relay/sodo）
2. 配置 agent 账户
3. 检测并修补 WSL 漏洞（如适用）
4. 完成安装

### 使用

Agent 需要提权时，调用 `/nas-elevate` skill：

```
Agent: I need to install nginx. May I request elevated access?
Human: Sure. [creates session following agent's instructions]
Agent: [sends commands, human watches in real-time]
Human: [closes session when done]
```

## 三种模式

| 模式 | 适用场景 | 特点 |
|------|---------|------|
| **direct** | 单 agent，完全信任 | 最简单，零开销，无令牌 |
| **relay** | 多 agent，需要隔离 | Daemon 管理，令牌认证 |
| **sodo** | 多 agent，无 daemon | sudoers 验证，令牌认证 |

## 文档

- [设计文档](docs/design.md) - 完整的架构与原理
- [Skills](skills/) - Agent 使用的技能
  - `nas-setup-guide` - 安装指导（README 引用，不安装）
  - `nas-elevate` - 运行时提权（安装后可用）

## 工作流程示例

### Direct 模式

```bash
# Human creates session
tmux new -s work
su - human

# Agent sends commands
tmux send-keys -t work "apt update" Enter
tmux capture-pane -t work -p

# Human closes session
tmux kill-session -t work
```

### Relay/Sodo 模式

```bash
# Human creates session with token
nmux create work
# Token: abc-123-def

# Agent attaches
echo "abc-123-def" | nmux attach work --token -

# Agent sends commands
nmux send work "apt update"
nmux read work

# Human closes
tmux kill-session -t work
```

## 安全特性

✓ **默认无权**：Agent 在低权限账户运行  
✓ **显式授权**：人类主动创建会话才能提权  
✓ **实时监控**：人类看到每条命令，随时可中断  
✓ **即时销毁**：关闭 tmux = 权限失效，无残留  
✓ **令牌隔离**（relay/sodo）：多 agent 互不干扰  
✓ **WSL 加固**（可选）：修补已知提权绕过

## 贡献

欢迎提交 Issue 和 Pull Request。

## License

MIT

## 致谢

本项目受 remote-sudo-tmux 启发，专注于为 Agent 提供安全、透明、易用的提权机制。

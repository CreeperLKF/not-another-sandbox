# not-another-sandbox (NAS)

> **不是又一个试图困死 Agent 的静态沙箱，而是面向终端协作的“有人值守权限委托”机制。**

让 AI Agent 平时运行在低权限操作系统账户下；需要提权时，由人类现场开启受控终端会话，全程可见、随时关闭即撤权。

## 核心准则

0. **简单到眼睛**：零编译依赖，纯原生工具与短小可逐行审计的脚本
1. **授权之前，和操作系统一样安全**：平时依托 OS 原生用户隔离，默认无权
2. **授权之后，和用户一样的权力**：不做脆弱的命令白名单，风险兜底交给人类实时观测与随时撤权

---

## 快速开始（默认：`direct` 模式）

**`direct` 是默认安装模式**——零额外二进制、零后台进程、零 sudoers 修改，只需 `bash` + `tmux` + `/nas-elevate` Skill。

### 1. 安装

```bash
git clone https://github.com/CreeperLKF/not-another-sandbox.git
cd not-another-sandbox
./install.sh
```

`install.sh` 默认选择 `direct` 模式，完成以下配置：
- 创建（或指定）低权限 Agent 账户（默认 `nas-agent`）
- 检测 WSL 互操作提权风险（如适用）
- 安装并渲染运行时技能 `/nas-elevate` 到 Agent 账户

> 也可以直接把 [skills/nas-setup-guide/SKILL.md](skills/nas-setup-guide/SKILL.md) 交给运行在人类账户的 Agent，由它一步步引导你完成安装。

### 2. 日常使用（`direct` 模式）

当 Agent 需要高权限时，触发 `/nas-elevate`：

```bash
# 1. 人类在 agent 账户中创建 tmux，并在会话内提权到 human（或 root）
tmux new -s work
su - <human>

# 2. Agent 通过原生 tmux 注入指令并读取屏幕，人类全程实时观看
tmux send-keys -t work "apt update" Enter
tmux capture-pane -t work -p

# 3. 完成后人类关闭会话，权限即时收回
exit  # 或 tmux kill-session -t work
```

`direct` 模式适用于**单 Agent 或同机多 Agent 互信**场景（任何同 UID 进程均可访问该 tmux socket）。

---

## 高级模式：多 Agent 令牌隔离（`sodo` 模式）

如果你在同一 Agent 账户下运行**多个互不信任的 Agent**，希望只有持有本次会话临时令牌的 Agent 才能操作提权窗口，可启用高级模式 `sodo`：

### 安装 `sodo` 模式

```bash
./install.sh --mode sodo
```

仅依赖 `bash` + `tmux` + `sudo`（**零编译**），安装内容仅包含：
- `/usr/local/bin/nmux`：单文件纯 Shell 脚本（`root:root`，`0755`）
- `/etc/nas/sodo.conf`：受信任账户配置（`root:root`，`0644`）
- `/etc/sudoers.d/nas-sodo`：仅允许 Agent 免密以 Human 身份调用 `/usr/local/bin/nmux`

### 使用 `sodo` 模式

```bash
# 1. 人类在 human 账户创建隔离会话（令牌仅存于该独立 tmux server 内存中）
nmux create work
# 输出 Session: work / Token: <uuid>，复制给指定 Agent 后按 Enter 进入终端盯屏

# 2. Agent 每次调用通过 stdin 传递令牌（绝不经由命令行参数，防止 ps/cmdline 泄漏）
printf '%s\n' "$TOKEN" | nmux work send-keys -t work "apt update" Enter
printf '%s\n' "$TOKEN" | nmux work capture-pane -t work -p

# 3. 人类关闭 tmux 会话（exit 或 nmux kill work）
# 独立 tmux server 随之退出，内存令牌自动销毁，零文件残留
```

### 卸载

```bash
./uninstall.sh
```

自动清理 `/etc/sudoers.d/nas-sodo`、`/usr/local/bin/nmux`、`/etc/nas/`、Agent 配置与 Skill（不会自动删除 Agent 用户账户，如需删除请手动 `sudo userdel -r <agent>`）。

---

## 模式对比

| 维度 | `direct`（默认） | `sodo`（高级） |
|---|---|---|
| **适用场景** | 单 Agent / 互信多 Agent | 同 UID 下多 Agent 隔离 |
| **依赖** | `bash` + `tmux` | `bash` + `tmux` + `sudo` |
| **额外组件** | 无 | 单文件 `/usr/local/bin/nmux` |
| **系统侵入** | 无 | 1 条 `/etc/sudoers.d/nas-sodo` |
| **令牌与隔离** | 无（OS UID 边界） | 独立 `tmux -L nmux-<session>` + 内存 `@nmux_token` + stdin 传钥 |
| **生命周期** | 关闭 tmux 即失效 | 关闭 tmux 即 server 退出、令牌自动销毁 |

## 文档

- [设计文档](docs/design.md) — 架构原理、双重身份模型、安全边界与 WSL 风险说明
- [skills/nas-setup-guide/SKILL.md](skills/nas-setup-guide/SKILL.md) — 面向安装助手的引导 Skill（不安装）
- [skills/nas-elevate/SKILL.md](skills/nas-elevate/SKILL.md) — 面向 Agent 的运行时提权 Skill

## License

MIT

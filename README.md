<div align="center">

# not-another-sandbox (NAS)

**不是又一个试图困死 Agent 的静态沙箱，而是面向终端协作的「有人值守权限委托」机制。**

*Don't build another leaky cage. Give your agent OS-native isolation by default, and lend it your terminal only while you're watching.*

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](#license)
[![Zero Compile](https://img.shields.io/badge/Build-Zero%20Compile-brightgreen.svg)](#快速开始默认direct-模式)
[![Dependencies](https://img.shields.io/badge/Deps-bash%20%2B%20tmux-orange.svg)](#模式对比)

</div>

---

## 为什么不是又一个沙箱？

给 Coding Agent（Claude Code / Codex / OpenCode 等）分配权限时，大多数方案都在两个极端之间摇摆：

- **裸奔模式**：让 Agent 直接跑在你的主账户下，甚至开启自动放行——一次幻觉或 Prompt Injection 就可能删掉代码、改坏配置或碰触 `~/.ssh`。
- **静态沙箱**：套上容器、seccomp 或层层叠叠的命令白名单——一旦需要 `apt install`、操作 `docker`、调试 `systemd` 或改 `/etc`，你就不得不停下来与沙箱斗智斗勇；而且命令白名单天然脆弱、极易绕过。

**not-another-sandbox 换了一种思路：**

> 平时用操作系统最原生、最可靠的**低权限用户隔离**；真正需要高权限时，由人类现场打开一个受控终端会话，把键盘临时借给 Agent，**全程实时可见，敲一个 `exit` 立刻收回一切权限**。

```text
  平时（默认无权）              需要提权（人类在场）                任务完成（即时撤权）
┌──────────────────┐        ┌──────────────────────────┐        ┌──────────────────┐
│  agent 低权限账户  │ ──请求─▶│  人类开启 tmux 高权限会话  │ ──关闭─▶│  会话销毁，零残留  │
│  OS 原生权限边界   │        │  Agent 注入命令 / 人类盯屏 │        │  回到低权限状态    │
└──────────────────┘        └──────────────────────────┘        └──────────────────┘
```

### 三条基本准则

0. **简单到眼睛**：零编译、零容器、零常驻守护进程，核心代码只有几百行纯 Shell 与两份 Skill，两分钟就能逐行审计完。
1. **授权之前，和操作系统一样安全**：平时依托 Linux 原生 UID 与文件权限边界，Agent 没有任何默认提权路径。
2. **授权之后，和用户一样的权力**：不做脆弱的命令白名单，风险兜底完全交给人类实时观测与随时关窗撤权。

---

## 快速开始（默认：`direct` 模式）

**`direct` 是推荐且默认的安装模式**——零额外二进制、零 `sudoers` 修改、零卸载负担，只需要 `bash` + `tmux`。

### 方式 A：直接运行安装脚本

```bash
git clone https://github.com/CreeperLKF/not-another-sandbox.git
cd not-another-sandbox
./install.sh
```

`install.sh` 默认选择 `direct` 模式，引导你完成三件事：
1. 创建或指定低权限 Agent 账户（默认 `nas-agent`）；
2. 检测 WSL 互操作提权风险（如运行在 WSL 下）；
3. 自动向 Agent 账户渲染并安装运行时技能 `/nas-elevate`。

### 方式 B：让你当前的 Agent 引导你安装

直接把 [skills/nas-setup-guide/SKILL.md](skills/nas-setup-guide/SKILL.md) 交给运行在人类账户中的 Agent，它会根据你的环境（单 Agent / 多 Agent、是否 WSL）交互式引导完成配置与首次演练。

---

## 日常体验长什么样？

平时 Agent 在 `nas-agent` 账户里安心写代码、跑测试。当它遇到需要权限的任务时，自动触发 `/nas-elevate`：

> **Agent**：我需要安装 `nginx` 并开放 8080 端口，计划执行 `apt update && apt install -y nginx`。请帮我开一个监督会话：
> ```bash
> # 在 agent 账户执行
> tmux new -s work
> su - <your-user>
> ```
>
> **Human**：打开终端跑完上面两行，输入自己的密码，回复「好了」。
>
> **Agent**（通过原生 `tmux` 离散地发送输入并读取屏幕快照）：
> ```bash
> tmux send-keys -t work "sudo apt update && sudo apt install -y nginx" Enter
> tmux capture-pane -t work -p
> ```
>
> **Human**：在自己的 tmux 窗口里实时看着每一条命令跑完；一旦发现异常，直接关掉 tmux 瞬间中断。
>
> **Agent**：安装已完成，你可以关闭会话了。
>
> **Human**：`exit` —— 提权窗口消失，一切恢复如初。

---

## 给人类读的速查手册（For Humans）

如果你平时不常折腾 Linux 多用户或 `tmux`，只需要掌握下面这两张极简速查表，就足够安全、顺手地驾驭整套流程。

### 1. 操作系统多账户基础

Linux / macOS 的**多用户隔离**是经过数十年实战验证的内核级安全边界：每个用户拥有独立的 UID、家目录与文件权限。把 Agent 放在一个无 `sudo` 权限的低权限账户（例如 `nas-agent`）里，它默认就读不到你的 `~/.ssh`、改不了系统配置，也删不掉属于你主账户的受保护文件。

| 你想做什么 | 命令 | 说明 |
|---|---|---|
| 确认当前身份 | `whoami` / `id` | 查看当前用户名、UID 及所属用户组 |
| 切入 Agent 账户干活 | `sudo -u nas-agent -i` | 在这个 shell 里启动你的 Coding Agent |
| 创建低权限 Agent 账户 | `sudo useradd -m -s /bin/bash nas-agent` | `install.sh` 会自动帮你执行 |
| 在会话内提权回人类账户 | `su - <your-user>` | `direct` 模式下在 tmux 内输入自己密码提权 |
| 授权某个项目目录给 Agent | `sudo chown -R nas-agent:nas-agent /path/to/proj` | 或用用户组 + `chmod g+rwX` 共享目录 |
| 彻底删除 Agent 账户 | `sudo userdel -r nas-agent` | `uninstall.sh` 不会自动删账户，需要时手动执行 |

> **小贴士**：`direct` 模式下，人类需要在 **Agent 账户**里先开 `tmux`，再在 tmux 里 `su - <your-user>`；`sodo` 模式下，人类直接在**自己的主账户**里运行 `nmux create <session>` 即可。

### 2. `tmux` 极简操作指南

`tmux` 是终端复用器，你可以把它理解成“**一块你和 Agent 共同盯着看的共享终端屏幕**”。记住以下几个操作即可应对 99% 的日常与紧急场景：

| 操作 | 命令 / 快捷键 | 说明 |
|---|---|---|
| 新建会话 | `tmux new -s work` | 创建名为 `work` 的会话并自动进入 |
| 查看当前所有会话 | `tmux ls` | 随时检查是否有忘记关闭的孤儿会话（`sodo` 用 `nmux ls`） |
| 重新连接（Attach） | `tmux attach -t work` | 回到已有会话继续盯屏（`sodo` 用 `nmux attach work`） |
| 暂时脱离（Detach） | 先按 `Ctrl+b`，松手再按 `d` | 退出当前视图，**会话仍在后台运行**（注意：脱离不等于撤权！） |
| 正常退出并关闭 | 输入 `exit` 或按 `Ctrl+d` | 关闭当前 shell；若在 `su -` 内需退到整个 tmux 会话关闭 |
| **强行终止（紧急熔断）** | 会话内：`Ctrl+b` → 输入 `:kill-session` 回车<br>会话外：`tmux kill-session -t work` | **看到任何不对劲的命令，立刻强杀会话**，权限瞬间作废（`sodo` 用 `nmux kill work`） |
| 一键清空全部会话 | `tmux kill-server` | 核选项：立即关闭当前用户下的所有 tmux 会话 |

---

## 给智能体读的安装说明（For Agents）

> **如果你是一个 AI Agent，且人类让你协助安装或配置 `not-another-sandbox`，请按以下指示执行：**

1. **先阅读安装引导 Skill**：完整读取 [skills/nas-setup-guide/SKILL.md](skills/nas-setup-guide/SKILL.md) 并严格按其步骤与人类交互（不要跳过确认环节，也不要在未说明风险的情况下修改 `sudoers`）。
2. **默认推荐 `direct` 模式**：向人类确认场景后，默认推荐零侵入的 `direct` 模式；仅在同 UID 多 Agent 互不信任场景下推荐 `sodo` 模式，并提前告知 `./uninstall.sh` 可完整卸载。
3. **完成安装与连通性验证**：协助运行 `./install.sh`（按需检测 WSL 互操作风险），并引导人类跑通一次最简 `whoami` 提权验证。
4. **安装后主动向人类做上手交接**：安装完成后，用简洁清晰的语言向人类介绍：
   - 日常应如何进入低权限账户运行 Agent（如 `sudo -u <agent> -i`）；
   - 当 Agent 触发 `/nas-elevate` 请求提权时，人类在当前已装模式（`direct` 或 `sodo`）下需要敲哪几条命令；
   - 如何实时盯屏、如何通过 `exit` 正常关闭、发现异常如何用 `tmux kill-session` / `nmux kill` 强行断权，以及定期用 `tmux ls` / `nmux ls` 排查孤儿会话。

---

## 进阶模式：多 Agent 令牌隔离（`sodo` 模式）

在 `direct` 模式下，同一个 `agent` UID 下的所有进程都能访问该 tmux socket（适合单 Agent 或彼此完全信任的多 Agent）。

如果你在同一低权限账户下运行**多个互不信任的 Agent**，希望**只有拿到本次临时令牌的那个 Agent**才能操作提权窗口，可以启用高级模式 `sodo`：

### 安装

```bash
./install.sh --mode sodo
```

依然**零编译**（仅依赖 `bash` + `tmux` + `sudo`），只安装三个极简文件：
- `/usr/local/bin/nmux` — 单文件纯 Shell 门闸（`root:root`，`0755`）
- `/etc/nas/sodo.conf` — 受信任的 `HUMAN_USER` / `AGENT_USER` 配置（`root:root`，`0644`）
- `/etc/sudoers.d/nas-sodo` — 仅放行 `agent` 免密以 `human` 身份调用 `/usr/local/bin/nmux`（启用 `env_reset`）

### 使用流程

```bash
# 1. 人类在 human 账户创建隔离会话
nmux create work
# Session: work
# Token:   e7660c53-c9ba-4006-9b45-013fdf30f80b
# 复制 Token 给目标 Agent 后，按 Enter 进入 tmux 实时盯屏

# 2. Agent 每次调用通过 stdin 传递令牌，完整透传任意 tmux 子命令
printf '%s\n' "$TOKEN" | nmux work send-keys -t work "apt update" Enter
printf '%s\n' "$TOKEN" | nmux work capture-pane -t work -p

# 3. 人类关闭会话（窗口内 exit 或 nmux kill work）
# 独立 tmux server 随之退出，内存令牌瞬间销毁，零文件残留
```

### `sodo` 模式如何守住边界？

- **令牌不落盘**：每个会话运行在独立的 `tmux -L nmux-<session>` server 中，随机 UUID 仅存在该 tmux 进程内存（`@nmux_token`）里，连 `/dev/shm` 都不写；关闭 tmux 即物理销毁。
- **令牌不进 `ps` / `cmdline`**：强制要求经由 **stdin** 传递令牌并穿透 `sudo -n`，同 UID 下的其他 Agent 无法通过 `/proc/<pid>/cmdline` 窃取。
- **无白名单透传，但封死逃逸**：严格校验会话名正则（杜绝 `../` 路径穿越与假 tmux server 伪造），禁止透传 `-L`/`-S`/`-f` 等 tmux 全局参数（杜绝跨会话逃逸到人类个人 tmux 或读取敏感文件），同时无限制透传所有 tmux 子命令。
- **可逆且干净卸载**：随时运行 `./uninstall.sh` 一键移除 `sudoers` 规则、`/usr/local/bin/nmux`、配置、Skill 及活跃会话（不会误删 Agent 用户账户）。

---

## 模式对比

| 维度 | `direct`（默认） | `sodo`（高级） |
|---|---|---|
| **适用场景** | 单 Agent / 同机互信多 Agent | 同 UID 下多 Agent 互不信任 |
| **依赖** | `bash` + `tmux` | `bash` + `tmux` + `sudo` |
| **额外组件** | 无（原生 `tmux`） | 单文件纯 Shell `/usr/local/bin/nmux` |
| **系统侵入性** | 零侵入 | 1 条 `/etc/sudoers.d/nas-sodo`（配套 `uninstall.sh`） |
| **认证与隔离** | OS 原生 UID 边界 | 独立 `tmux -L` + 内存 `@nmux_token` + stdin 传钥 |
| **撤权方式** | 关闭 tmux | 关闭 tmux（server 退出即令牌失效） |

---

## 安全边界与坦诚说明

我们更愿意把假设和边界摆在明面上：

1. **不做命令审查，靠人眼兜底**：NAS 的核心是“控制谁能跨过边界 + 全程可视化 + 随时拔电源”，不承诺靠命令白名单拦截恶意参数。在 `sodo` 模式下，持有合法令牌的 Agent 被视作已获该会话的完整 tmux 控制权。
2. **WSL 环境的已知绕过面**：在默认 WSL2 中，`/run/WSL/*_interop` socket 权限为 `0777`，任意低权限用户理论上都能通过 `wsl.exe -u root` 绕过 Linux 账户隔离。`install.sh` 会主动检测该风险并可写入 Agent 软提醒；若需强安全边界，请在 WSL 侧关闭 interop 或加固 `/init`。
3. **关注孤儿会话**：提权结束后请确认关闭对应的 tmux 会话（随时用 `tmux ls` 或 `nmux ls` 检查）。

---

## 项目结构

整个仓库只有 7 个核心文件，打开就能读完：

```text
not-another-sandbox/
├── README.md                        # 你正在看的文档
├── install.sh                       # 交互 / 非交互安装脚本（默认 direct）
├── uninstall.sh                     # 干净卸载脚本
├── scripts/
│   └── nmux                         # sodo 模式单文件纯 Shell 入口
├── skills/
│   ├── nas-setup-guide/SKILL.md     # 安装引导 Skill（供人类侧 Agent 读取）
│   └── nas-elevate/SKILL.md         # 运行时提权 Skill（安装到 Agent 账户）
└── docs/
    └── design.md                    # 完整架构设计与安全不变量
```

## 延伸阅读

- [完整设计文档 (docs/design.md)](docs/design.md) — 双重身份模型、Act–Observe 范式、攻击面分析与 WSL 加固说明
- [安装引导 Skill (skills/nas-setup-guide/SKILL.md)](skills/nas-setup-guide/SKILL.md)
- [运行时提权 Skill (skills/nas-elevate/SKILL.md)](skills/nas-elevate/SKILL.md)

## 致谢与灵感来源

- **实践启发**：受 `remote-sudo-tmux` 实践启发，以原生 `tmux` 终端协作回归简单、透明、随时可撤权的权限委托。
- **理论思路**：受论文 [We Query, Therefore We Compute: On Oracle Computation beyond the Machine, with an Application to Agents (arXiv:2610.09243)](https://arxiv.org/abs/2610.09243) 启发——该文系统推导了一个严谨的 Agent 操作系统应当如何构建。

## License

本项目基于 **MIT License** 开源。

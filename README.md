<div align="center">

# not-another-sandbox (NAS)

**不是又一个试图困死 Agent 的静态沙箱，而是面向终端协作的「有人值守权限委托」机制。**

*Don't build another leaky cage. Give your agent OS-native isolation by default, and lend it your terminal only while you're watching.*

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](#license)
[![Zero Compile](https://img.shields.io/badge/Build-Zero%20Compile-brightgreen.svg)](#快速开始)
[![Dependencies](https://img.shields.io/badge/Deps-bash%20%2B%20tmux-orange.svg)](#架构)

**简体中文** | [English](README.en.md)

</div>

---

## 为什么不是又一个沙箱？

给 Coding Agent（Claude Code / Codex / OpenCode 等）分配权限时，大多数方案都在两个极端之间摇摆：

- **裸奔模式**：让 Agent 直接跑在你的主账户下，甚至开启自动放行——一次幻觉或 Prompt Injection 就可能删掉代码、改坏配置或碰触 `~/.ssh`。
- **静态沙箱**：套上容器、seccomp 或层层叠叠的命令白名单——一旦需要 `apt install`、操作 `docker`、调试 `systemd` 或改 `/etc`，你就不得不停下来与沙箱斗智斗勇；而且命令白名单天然脆弱、极易绕过。

**not-another-sandbox 换了一种思路：**

```text
┌─────────────────────────────────────────────────────────────┐
│  默认：Agent 跑在独立的低权限系统用户下                     │
│        （UID 隔离，没有 sudo，也碰不到你的家目录）          │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ 需要提权时
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  提权：你手动打开一个受监督的 tmux 会话                     │
│        Agent 输入命令 · 你实时看着                          │
│        exit / kill-session → 权限立刻收回                   │
└─────────────────────────────────────────────────────────────┘
```

---

## 快速开始

```bash
git clone https://github.com/CreeperLKF/not-another-sandbox.git
cd not-another-sandbox
./install.sh          # 默认 direct 模式
```

然后在低权限账号里启动你的 Agent：

```bash
sudo -u nas-agent -i
# 在这里启动 claude / codex / opencode 等
```

当 Agent 需要提权时，它会告诉你如何打开监督会话（见 [使用方法](#使用方法)）。

也可以让 Agent 带你安装：把 [skills/nas-setup-guide/SKILL.md](skills/nas-setup-guide/SKILL.md) 丢给它即可。

---

## 架构

```text
                    ┌──────────────────┐
                    │   人类账号       │  ← 日常使用
                    │   (你的 UID)     │
                    └────────┬─────────┘
                             │ 打开受监督会话
                             │ (tmux / nmux)
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                      受监督提权                             │
│                                                             │
│   你看着 pane  ←→  Agent 通过 tmux 注入按键                 │
│                                                             │
│   exit / kill-session  →  权限立刻结束                      │
└─────────────────────────────────────────────────────────────┘
                             ▲
                             │ 请求提权
                             │
                    ┌────────┴─────────┐
                    │  Agent 账号      │  ← 默认运行环境
                    │  (nas-agent)     │
                    │  低权限          │
                    └──────────────────┘
```

两种模式决定 Agent 如何接触到提权 pane：

| | `direct`（默认） | `sodo`（进阶） |
|---|---|---|
| **谁能接触 pane** | Agent UID 下的任何进程 | 只有持有临时 token 的 Agent |
| **人类如何开会话** | 在 Agent 账号里 `tmux new -s work` 然后 `su - <你>` | 在人类账号里 `nmux create work` |
| **Agent 如何发键** | `tmux send-keys ...` | `printf '%s\n' "$TOKEN" \| nmux work send-keys ...` |
| **额外安装** | 无 | `/usr/local/bin/nmux` + 一条 `sudoers` 规则 |
| **适合场景** | 单个 Agent 或信任的 Agent | 多个 Agent 共用同一 UID |

`sodo` 的 token 只存在于隔离 tmux server 的内存中，通过 stdin 传递（不会出现在 `argv`）。销毁 server 即清除。

---

## 使用方法

> 不熟悉 Linux 多账户或 `tmux` 基本操作？先看一眼 [速查手册 (docs/cheatsheet.md)](docs/cheatsheet.md)。

### 日常操作

Agent 保持在 `nas-agent` 账号。写代码、跑测试等不需要提权。

### 需要提权时

Agent 会调用 `/nas-elevate`，并明确告诉你该运行什么。

**`direct` 模式**（在 **Agent 账号** 中执行）：

```bash
tmux new -s nginx-setup
su - <你的用户名>          # 输入你的密码
# （可选）sudo -v          # 如果需要 root
```

之后 Agent 用 `tmux send-keys` / `tmux capture-pane` 驱动 pane，你实时看着。

结束后：在 pane 里反复 `exit`，或执行 `tmux kill-session -t nginx-setup`。

**`sodo` 模式**（在 **人类账号** 中执行）：

```bash
nmux create work
# 把打印出来的 token 交给 Agent，然后按 Enter 进入会话
```

Agent 每次调用都把 token 通过 stdin 传入。

结束后：在 pane 里 `exit`，或执行 `nmux kill work`。

### 紧急停止

```bash
tmux kill-session -t <session>     # direct
nmux kill <session>                # sodo
tmux kill-server                   # 核弹（清掉当前用户所有会话）
```

**Detach（`Ctrl+b d`）不会收回权限**，会话仍然存活。务必 `exit` 或显式 `kill`。

---

## 安全边界

NAS 不过滤命令。它控制的是「谁能跨过边界」，并让这次跨越可见、可立刻收回。

| NAS 能防的 | NAS 不防的 |
|---|---|
| Agent 默认读取你的 `~/.ssh` 或家目录 | 你已授权会话后执行的恶意命令 |
| 你不知情的意外提权 | 内核漏洞或未加固的 WSL interop 绕过（见下文） |
| 提权会话被遗忘（只要你检查 `tmux ls` / `nmux ls`） | 提权期间启动的、生命周期超过会话的后台任务 |

---

## WSL 加固（可选）

默认 WSL2 会把 `/run/WSL/*_interop` 设为 `0777`（任意本地用户可通过 `wsl.exe -u root` 绕过账号隔离），且 `/mnt/c` 等盘符默认全局可访问。

NAS 内置了一键可选加固开关（保留人类账号与 VSCode Remote-WSL 的互操作体验）：

```bash
./install.sh --harden-wsl
```

它会自动完成两件事（均可由 `./uninstall.sh` 还原）：
1. 安装并启用 `nas-wsl-interop.{path,service}`（含 `StartLimitIntervalSec=0`），监听 `/run/WSL` 并将 interop socket 权限收紧为 `0770`（`root:<人类所属组>`）；
2. 在 `/etc/wsl.conf` 配置 `[automount] umask=077`，使 `/mnt/*` 盘符仅对人类与 `root` 可访问（需执行一次 `wsl.exe --terminate <Distro>` 重启生效，请将协作项目放在 Linux 原生文件系统中）。

这不是完美方案（新开宿主机 `wsl.exe` 会话瞬间存在短暂竞争窗口），但对大多数日常场景已经足够实用。完全关闭 interop 或使用更严格的边界仍需在 WSL 层额外处理（如设置 `[interop] enabled=false`）。

---

## 模式细节

### `direct`（默认）

不引入额外二进制。人类在 Agent 账号里开 `tmux`，用 `su` 提权并盯着。Agent UID 下的任何进程都能接触 pane —— 单个 Agent 时完全够用。

### `sodo`（进阶）

适合多个 Agent 共用同一 UID。每个会话使用独立的 tmux server（`tmux -L nmux-<session>`）和内存中的 token。只有持有该 token 的进程能与 pane 交互。token 不会落盘，也不会出现在 `/proc/<pid>/cmdline`。

安装：

```bash
./install.sh --mode sodo
```

卸载（会删除 `sudoers`、`nmux`、WSL 加固单元及配置，不会删除 Agent 用户）：

```bash
./uninstall.sh
```

---

## 项目结构

```text
not-another-sandbox/
├── README.md                        # 中文说明文档
├── README.en.md                     # 英文说明文档
├── install.sh                       # 交互 / 非交互安装脚本（默认 direct）
├── uninstall.sh                     # 干净卸载脚本
├── scripts/
│   └── nmux                         # sodo 模式单文件纯 Shell 入口
├── skills/
│   ├── nas-setup-guide/SKILL.md     # 安装引导 Skill（供人类侧 Agent 读取）
│   └── nas-elevate/SKILL.md         # 运行时提权 Skill（安装到 Agent 账户）
├── docs/
│   ├── cheatsheet.md                # 给人类读的多账户与 tmux 速查手册（中文）
│   ├── cheatsheet.en.md             # 给人类读的多账户与 tmux 速查手册（英文）
│   ├── design.md                    # 完整架构设计与安全不变量（中文）
│   └── design.en.md                 # 完整架构设计与安全不变量（英文）
└── tests/
    ├── test-nas.sh                  # direct / sodo 端到端回归测试
    └── test-wsl-harden.sh           # WSL2 --harden-wsl 端到端测试
```

## 延伸阅读

- [给人类读的速查手册 (docs/cheatsheet.md)](docs/cheatsheet.md) — Linux 多账户操作与 `tmux` 常用快捷键速查
- [完整设计文档 (docs/design.md)](docs/design.md) — 双重身份模型、Act–Observe 范式、安全不变量与 WSL 加固细节
- [安装引导 Skill (skills/nas-setup-guide/SKILL.md)](skills/nas-setup-guide/SKILL.md)
- [运行时提权 Skill (skills/nas-elevate/SKILL.md)](skills/nas-elevate/SKILL.md)

## 致谢与灵感来源

- **实践启发**：受 `remote-sudo-tmux` 实践启发，以原生 `tmux` 终端协作回归简单、透明、随时可撤权的权限委托。
- **理论思路**：受论文 [We Query, Therefore We Compute: On Oracle Computation beyond the Machine, with an Application to Agents (arXiv:2610.09243)](https://arxiv.org/abs/2610.09243) 启发——该文系统推导了一个严谨的 Agent 操作系统应当如何构建。

## License

本项目基于 **MIT License** 开源。

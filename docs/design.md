# not-another-sandbox (NAS) / nmux — 设计文档

**简体中文** | [English](design.en.md)

> **不是又一个试图困死 Agent 的静态沙箱，而是一套面向终端协作的“有人值守权限委托（Attended Privilege Delegation）”机制。**

---

## 1. 核心理念

### 问题与取舍

Coding Agent 在日常开发与系统运维中面临经典两难：
- **静态沙箱过严**：无法完成安装依赖、修改系统配置等正常开发任务，且命令白名单极易绕过、维护成本高。
- **直接给高权限过松**：任何误操作或 Prompt Injection 都可能波及宿主系统。

NAS 转向更务实的范式：
- **平时靠 OS 原生隔离**：Agent 运行在独立低权限账户下，默认没有任何提权通道。
- **提权靠人类现场授权**：由人类开启受控终端会话并临时委托 Agent 介入，全程可见、关闭即撤权。

### 三个基本准则

0. **简单到眼睛**：零编译依赖，机制直观，任何人都可在数分钟内逐行审计。
1. **授权之前，提供和操作系统一样的安全**：依托 OS 原生 UID/文件权限边界。
2. **授权之后，提供和用户一样的权力**：不维护脆弱的子命令白名单，风险兜底交给人类实时观测与随时终止。

---

## 2. 架构抽象

### 权限等级模型

```
root  (UID 0)      ← 系统管理员
  ↓
human (UID 1000)   ← 人类日常开发账户（Agent 提权目标，或由人类在会话内继续 sudo）
  ↓
agent (UID 1001+)  ← Agent 运行账户，默认无特权
```

### 正交的双重身份模型

- **执行身份（Execution Identity）**：由内核强制保障的终端执行主体（`human` 或 `root`），决定命令实际拥有什么权限。
- **输入主体（Input Principal）**：向该终端发送键盘输入的操作者（人类或持有令牌的特定 Agent）。

底层会话始终由人类掌控并实时旁观，Agent 获得的只是“在会话存活期间向其发送离散输入并读取屏幕快照”的临时委托权。

### 离散的“动作—观测”范式（Act-Observe）

直接复用原生 `tmux` 的终端渲染与状态保持能力：
- **Act**：`send-keys` 注入命令
- **Observe**：`capture-pane -p` 读取纯文本屏幕快照

不自造流式 PTY 代理，也不维护与 `tmux` 平行演进的命令集。

---

## 3. 两种运行模式

NAS 提供一个**零依赖默认模式**与一个**多 Agent 隔离高级模式**：

| 特性 | `direct`（默认） | `sodo`（高级） |
|---|---|---|
| **隔离边界** | OS 原生用户与 tmux socket (`0700`) | `sudoers` + 独立 tmux server + 内存令牌 |
| **额外组件** | 无（直接调用原生 `tmux`） | 单文件纯 Shell `/usr/local/bin/nmux` |
| **系统配置** | 无 | `/etc/nas/sodo.conf` + `/etc/sudoers.d/nas-sodo` |
| **多 Agent 隔离** | 无（同 UID 下互信） | 有（仅持有会话令牌者可接入对应会话） |
| **依赖** | `bash` + `tmux` | `bash` + `tmux` + `sudo` |
| **凭据生命周期** | 无凭据，关闭 tmux 即结束 | 存于 tmux server 内存，关闭 tmux 即销毁 |

### 3.1 `direct` 模式（默认）

适合单 Agent 或本机多 Agent 互信环境：

```
Human (在 agent 账户):
  $ tmux new -s work
  $ su - <human>          # 在 tmux 内切换到人类账户（或按需 sudo）

Agent (在 agent 账户):
  $ tmux send-keys -t work "apt update" Enter
  $ tmux capture-pane -t work -p

Human 结束监督:
  $ exit                  # 关闭 tmux，权限立即失效
```

### 3.2 `sodo` 模式（高级，多 Agent 隔离）

当同一 `agent` UID 下运行多个互不信任的 Agent 时，启用 `sodo` 模式，通过**单文件 `/usr/local/bin/nmux`** 完成跨用户鉴权与透传：

```
Human (在 human 账户):
  $ nmux create work
    -> 启动独立 tmux server: tmux -L nmux-work new-session -d -s work
    -> 生成随机 UUID，经 stdin (`tmux source-file -`) 写入该 server 内存选项 @nmux_token（不进入 argv）
    -> 打印 Token，人类复制给指定 Agent 后按 Enter attach 盯屏

Agent (在 agent 账户):
  $ printf '%s\n' "$TOKEN" | nmux work send-keys -t work "apt update" Enter
    -> nmux 识别当前为 agent，自动执行:
       exec sudo -n -u <human> /usr/local/bin/nmux work send-keys -t work ...
       （stdin 原样穿透 sudo，token 绝不进入命令行参数）
    -> 提权后的 nmux（检测到 SUDO_USER 非空，强制走 Agent 鉴权路径）:
       1. 校验 session 名称正则与 tmux 子命令格式（拒绝 -L/-S/-f 等全局选项）
       2. 从 stdin 读取第一行 token
       3. 查询 tmux -L nmux-work show-option -gqv @nmux_token 比对
       4. 校验通过后 exec tmux -L nmux-work "$@"

Human 结束监督:
  $ exit 或 nmux kill work
    -> 独立 tmux server (nmux-work) 退出
    -> /tmp/tmux-<human_uid>/nmux-work 与内存 @nmux_token 自动消失，零残留
```

---

## 4. 关键安全不变量（`sodo` 模式）

1. **不可篡改的信任根**
   - `/usr/local/bin/nmux` 与 `/etc/nas/sodo.conf` 均由 `root:root` 持有且对 Agent 不可写；`nmux` 启动时校验配置文件非符号链接、属主为 `root` 且无组/其他写权限。
   - `nmux` 使用 `#!/bin/bash -p`、硬编码 `PATH`、`unset TMUX TMUX_TMPDIR`，并配合 sudoers 的 `Defaults!/usr/local/bin/nmux env_reset`，抵御环境变量注入（`BASH_ENV`/`TMUX_TMPDIR` 等）。
   - `nmux` 只要检测到 `SUDO_USER` 非空，强制进入 Agent 验权路径，杜绝通过 sudo 触发人类管理子命令（`create`/`kill` 等）。

2. **杜绝命令行参数泄漏凭据**
   - 同 UID（以及 Linux 默认 `hidepid=0` 下的其他本地用户）进程可读取 `/proc/<pid>/cmdline`。
   - 创建端通过 bash 内置 `printf` 经 stdin 管道（`tmux -L "$socket" source-file -`）写入 `@nmux_token`，调用端强制要求从 **stdin** 读取 token 并以 `sudo -n`（非交互模式）透传，确保 token 在全生命周期中都不进入任何子进程的 `argv`。

3. **会话名注入与跨会话逃逸防护**
   - `<session>` 严格校验匹配 `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$`，杜绝 `../` 路径穿越（防止指向 Agent 伪造的 tmux server 绕过鉴权）及 tmux target 分隔符注入。
   - 透传给 `tmux` 的首个参数严格校验匹配 `^[a-z][a-z0-9-]*$`，彻底禁止 `-L`、`-S`、`-f` 等全局参数覆盖独立 socket 或加载任意配置文件（防止逃逸到人类默认 tmux 或读取敏感文件），同时保持对全部 tmux 子命令的无白名单透传。

4. **凭据与会话同生共死**
   - 不使用 `/dev/shm` 或磁盘文件落盘 token；令牌仅存活于对应独立 tmux server 内存中。无单独 `revoke` 命令，销毁 tmux server 即彻底失效。

5. **设计边界说明**
   - **准入即全权（无白名单）**：一旦 Agent 持有有效令牌，即可向对应 `nmux-<session>` 发送任意 tmux 子命令（注：包含 `run-shell` 等非屏幕输出子命令，权限等价于已授权的 `human` 会话）；系统防线核心在于“未授权绝不可跨边界 + 跨会话隔离 + 人类值守与即时销毁”。
   - **同 UID 多 Agent 隔离边界（过渡方案定位）**：`sodo` 是同 UID 多 Agent 场景下的**会话级令牌准入（过渡安全方案）**，用于防止未持有当前令牌的其他 Agent 直接复用共享 tmux socket 或误操作提权会话。但由于共享同一 Linux UID 的进程在 OS 层面共享家目录（含对话记录、配置、Shell 环境等），令牌交付与保管仍依赖外部运行环境。若需要强对抗意义上的多 Agent 隔离，应为互不信任的 Agent 分配**独立 OS 账户**（回归 OS 原生 UID 边界）。
   - **撤权语义（`detach` vs `exit` / `nmux kill`）**：断开终端窗口或 `Ctrl-b d` 仅会 `detach` 客户端，独立 tmux server 与令牌依然存活；只有退出会话内全部 shell（`exit`）或执行 `nmux kill <session>` 销毁 server，旧令牌才会彻底失效、无法再通过该入口发起操作。遵循“授权之后与用户同等权力”原则，销毁 server 不会回滚已完成的文件修改或已脱离会话运行的后台任务。
   - **安装与卸载权限边界**：`install.sh` 支持同模式原地重装/升级（覆写二进制、配置与 Skill），从 `sodo` 切回 `direct` 时会检测旧的 `sudoers`/`nmux` 残留并要求先运行 `./uninstall.sh`，避免配置与实际授权分叉；Skill 安装/卸载在 Agent 账户具备 `npx` 时优先以 `AGENT_USER` 调用 `npx skills` 适配多 Agent，无 `npx` 或离线失败时自动回退至 `~/.claude/skills/nas-elevate`；`uninstall.sh` 仅以 root 清理系统级安装文件，Agent 家目录内的配置与 Skill 均以 `AGENT_USER` 自身权限清理。

---

## 5. WSL 环境加固说明（可选 `--harden-wsl`）

默认 WSL2 存在两处绕过 Linux 原生多用户隔离的默认暴露面：
1. **互操作 Socket 权限过宽**：`/run/WSL/*_interop` 由特权 `/init` 创建，属主为 `root:root` 且默认权限为 `0777`。任何低权限 Linux 账户即使未继承 `$WSL_INTEROP`，也可枚举 `/run/WSL/*_interop` 调用宿主机 `wsl.exe -u root` 跨账户提权。
2. **Windows 盘符全局可读写**：`/mnt/c`、`/mnt/d` 等 `drvfs`（`9p`）挂载默认不设 `umask`（权限 `0777`），低权限账户可直接读写宿主机用户目录（如 `/mnt/c/Users/<user>`）或调用宿主机 `.exe`。

NAS 在 `install.sh` 中提供统一的 `--harden-wsl` 可选开关（兼容 `direct` 与 `sodo` 模式，且可由 `uninstall.sh` 完整卸载回滚）：

- **运行时收紧 `/run/WSL/*_interop`（`0770 root:<group>`）**：
  - 安装 `nas-wsl-interop.path`（监听 `PathChanged=/run/WSL`）与 `nas-wsl-interop.service`（开机 `multi-user.target` 及目录变更时触发，二者均配置 `StartLimitIntervalSec=0` 防止高频打开会话触发 systemd 启动频控熔断）。
  - 注意不能简单使用 `chmod o=`（因 socket 属主为 `root:root`，仅去 `other` 会将人类自己的普通终端与 VSCode 终端互操作一并锁死），而是将属组设为人类独占主组（或共享主组环境下的专用系统组 `nas-interop`）并设 `0770`。
  - 效果：人类账户、`root` 及 VSCode Remote-WSL 互操作完全正常，且日常在 WSL 内调用 Windows 程序仅做 `connect()` 而不触发目录变更（零性能损耗、零额外日志）；低权限 `agent` 连接任意互操作 socket 均被内核拒绝（`EACCES`）。
- **挂载层收紧 `/mnt/*`（`umask=077`）**：
  - 在 `/etc/wsl.conf` 的 `[automount]` 段写入 `options = "uid=<human_uid>,gid=<human_gid>,umask=077"`（若用户已有自定义 `options` 则保留原配置并给出提示，绝不强行覆盖）。
  - 重启一次 WSL 实例生效后，所有 Windows 盘变为 `0700`：人类与 `root`（依托 `9p` `access=client` 与 `CAP_DAC_OVERRIDE`）正常访问，`agent` 既无法读写宿主机文件，也无法触及 `/mnt/c/.../wsl.exe` 二进制本身（需将协作代码库放在 Linux 原生文件系统中）。
- **坦诚边界（Best-Effort 定位）**：
  - 运行时 socket 收紧属于 **best-effort** 机制：当宿主机从 Windows 侧新拉起 `wsl.exe` 会话时，新 socket 在 systemd 完成 `chmod` 前存在数十毫秒级的创建窗口（日常在已启动的 VSCode 或 `tmux` 内开窗不会产生新 socket）。
  - 若开启了 WSLg 图形支持，`/mnt/wslg` 下的 X11/Wayland socket 仍对本地图形程序共享（如需关闭可在宿主机 `.wslconfig` 设 `guiApplications=false`）；若需彻底物理切断互操作，可在 `/etc/wsl.conf` 中配置 `[interop] enabled=false`。
  - 若用户未启用 `--harden-wsl`，`install.sh` 仍支持向 `/nas-elevate` Skill 注入软安全提醒（`--wsl-warning`）。

---

## 6. 仓库结构

```
not-another-sandbox/
├── README.md                        # 快速开始（中文）
├── README.en.md                     # 快速开始（英文）
├── install.sh                       # 交互/非交互安装脚本
├── uninstall.sh                     # 清理 sudoers、nmux、配置与 skill
├── scripts/
│   └── nmux                         # sodo 模式单文件纯 Shell 入口
├── skills/
│   ├── nas-setup-guide/SKILL.md     # 安装引导 Skill（README 引用，不安装）
│   └── nas-elevate/SKILL.md         # 运行时提权 Skill（安装时按模式渲染）
└── docs/
    ├── design.md                    # 本文档（中文）
    └── design.en.md                 # 设计文档（英文）
```

# not-another-sandbox (NAS) / nmux — 设计文档

> **不是又一个试图困死 Agent 的静态沙箱，而是一套面向终端协作的"有人值守权限委托（Attended Privilege Delegation）"机制。**

## 1. 核心理念

### 问题陈述

Coding Agent 的权限困境：
- **过度限制**：完全困在沙箱里，无法完成需要高权限的正常开发任务（安装依赖、配置系统、操作容器）
- **过度开放**：给 Agent sudo 权限，任何误操作或恶意行为都可能破坏整个系统

传统沙箱的两难：
- 静态边界要么太严（阻碍生产力）要么太松（失去安全保证）
- 命令白名单极易绕过，且难以维护

### NAS 的解决思路

**从"不可逾越的沙箱"到"有人值守的委托"**：

```
平时：Agent 在低权限账户运行
      ↓
需要提权：人类在自己的会话中开启授权窗口
      ↓
Agent 连接：持有凭证，在人类监督下操作
      ↓
完成退出：凭证失效，Agent 回到低权限状态
```

### 三个基本准则

0. **简单到眼睛**：设计清晰，易于理解和审计
1. **授权之前，我们提供和操作系统一样的安全**：默认无权，依托 OS 原生隔离
2. **授权之后，我们提供和用户一样的权力**：不做脆弱的命令过滤，风险兜底交给人类实时观测

---

## 2. 架构抽象

### 权限等级模型

```
root (UID 0)          ← 系统管理员
  ↓
human (UID 1000)      ← 普通用户，Agent 想要提权到的目标
  ↓
agent (UID 1001+)     ← Agent 运行账户，默认低权限
```

**核心目标**：让 agent 能在人类监督下临时获得 human 账户的权限，而不是永久 sudo。

### 正交的双重身份模型

NAS 将共享终端中的权限拆解为两个正交维度：

* **执行身份（Execution Identity）**：由操作系统内核强制保障的权限主体（human 或 root），决定会话内**能触及什么系统资源**
* **输入主体（Input Principal）**：此刻向终端发起交互的操作者（人类或特定 Agent），由 `nmux` 负责**准入鉴权与边界管控**

关键：**执行身份不变，只是输入主体切换了**。底层终端会话的执行身份始终是人类的，Agent 获得的是"向这个会话发送输入"的权利。

### 固定边界，而非审查内容

系统的安全保证落在"控制谁能跨过边界"，而不是"审查跨越边界的具体指令内容"：

* **上下文授权**：人类授予的是对特定会话的临时接入权，而非逐条审批命令
* **准入即全权（无白名单）**：一旦 Agent 通过会话鉴权，即拥有对该会话的完整操作能力；不做脆弱的命令白名单过滤
* **风险兜底**：完全交给人类实时观测与随时撤权（关闭 tmux）

### 离散的"动作—观测"交互范式

```
Agent 不是直接操作 PTY（复杂、易出错）
而是：
  action:  nmux send "ls -la"
  observe: output = nmux read
```

直接复用原生终端复用器（tmux）的屏幕状态渲染能力，以离散的输入注入与屏幕快照读取作为核心交互范式。不引入高复杂度的流式 PTY 代理，避免终端控制符污染 Agent 上下文。

### 生命周期与撤权

* **令牌仅在单次 session 中有效**：令牌与 tmux 会话生命周期绑定
* **无单独 revoke 操作**：关闭 tmux = 令牌失效，保持简单
* **会话凭据与隔离态仅存在于内存**：不落盘持久化，会话关闭即彻底销毁，无残留状态

---

## 3. 三种运行模式

为在不同安全假设与部署极简度之间灵活权衡，NAS 提供三种模式：

| 特性 | **direct** | **relay** | **sodo** |
|-----|-----------|----------|---------|
| **隔离机制** | OS 基础文件权限 | 内核级 IPC 边界 | OS 提权规则 + 内存态验权 |
| **二进制组件** | 无，直接用 tmux | `nmux` + `nmuxd` | `nmux` |
| **令牌验证** | 无 | 是 | 是 |
| **后台进程** | 无 | `nmuxd` daemon | 无 |
| **sudoers 配置** | 无 | 无 | 需要 |
| **安全边界** | tmux socket (0700) | daemon socket + 令牌 | sudo + 内存令牌文件 |
| **定位** | 效率最高，单 Agent | 安全边界最干净，多 Agent | 形态最极简，多 Agent |

### direct 模式（默认，单 Agent 场景）

**流程**：

```
Agent: "请在 agent 账户创建 tmux："
Human: $ tmux new -s work              # 在 agent (UID 1001) 账户执行
       $ su - human                     # 在 tmux 内切换到 human (UID 1000)
       
Agent: tmux send-keys -t work "apt install ..." Enter
       tmux capture-pane -t work -p
```

**特点**：
- 无额外组件，直接包装 tmux 命令
- 无令牌验证，假设本机所有 agent 同等可信
- 安全边界：tmux socket 权限 0700，只有同 UID 可访问
- **适用场景**：单 agent，或多个完全互信的 agent

### relay 模式（多 Agent，需要隔离）

**流程**：

```
Human: $ nmux create work              # 启动 nmuxd daemon（如果未运行）
       Session token: abc-def-123      # 生成临时令牌
       
Agent: nmux attach work --token abc-def-123
       → 连接到 nmuxd socket
       → daemon 验证令牌
       → 建立代理：agent ↔ daemon ↔ tmux
       
       nmux send work "apt install ..."  # 所有操作经过 daemon 转发
       nmux read work
```

**特点**：
- 有后台进程 `nmuxd` 管理令牌和会话
- 令牌验证，只有持有令牌的 agent 可连接
- Agent 始终停留在自身低权限身份下，仅通过受控通信通道传递数据
- **攻击面**：daemon socket 暴露，需要防护（SO_PEERCRED 验证）
- **适用场景**：多个互不信任的 agent

### sodo 模式（多 Agent，无常驻进程）

**流程**：

```
Human: $ nmux create work
       → 创建 tmux + su - human
       → 保存令牌到 /dev/shm/nmux-work （内存文件，权限 0600）
       Session token: abc-def-123
       
Agent: echo "abc-def-123" | nmux send-keys -t work "apt install ..." Enter
       → nmux 调用 sudo /usr/local/bin/nmux-verify <session> <token> exec -- tmux send-keys ...
       → nmux-verify 验证令牌（读取 /dev/shm/nmux-work 比对）
       → 验证通过后执行 tmux 命令
       
       echo "abc-def-123" | nmux capture-pane -t work -p
```

**特点**：
- 无后台进程，每次操作都通过 sudo 调用验证脚本
- **为什么需要 nmux-verify**：不能让 agent 直接 `sudo tmux`（会绕过令牌验证），必须通过守门员脚本
- Sudoers 配置：`agent ALL=(human) NOPASSWD: /usr/local/bin/nmux-verify`
- 每次操作传入令牌（stdin），验证后转发给 tmux（无命令白名单）
- 侵入性配置：需要 sudoers 规则，提供 uninstall.sh 清理
- 性能开销：每次操作都触发 sudo
- **适用场景**：多 agent，不想跑 daemon，接受 sudoers 侵入性

---

## 4. 关键安全约束

设计落地时必须严格守住以下约束：

### 1. 不可篡改的信任根

- `nmux` 入口本身必须由系统管理员持有且对 Agent 只读，防止被篡改逻辑
- 在非 direct 模式下，底层原生会话通道（tmux socket）必须对 Agent 严格不可访问

### 2. 令牌泄漏防护

**问题**：同 UID 下的其他进程可以读取 `/proc/<pid>/cmdline` 和 `/proc/<pid>/environ`

**方案**：

- **标准输入传递**（推荐）：
  ```bash
  echo "$TOKEN" | nmux attach work --token -
  ```

- **SO_PEERCRED 验证**（relay daemon）：
  - daemon accept 时检查连接来自 agent UID
  - 令牌只验证一次，后续靠 socket 持久连接

- **内存文件 + 严格权限**（sodo）：
  ```bash
  TOKEN_FILE=/dev/shm/nmux-$SESSION
  chmod 600 "$TOKEN_FILE"
  ```

### 3. 多 Agent 互不信任模型

- 一个会话可以因为令牌被共享而授权给多个 agent
- 父子 agent 令牌传递行为不干预，由上层决定
- 同一令牌可以被多个进程同时使用（relay 模式通过 socket 连接池管理）

### 4. 不设指令白名单，明确责任边界

鉴权通过即代表该会话内对 Agent 的完全操作授权，系统不承诺通过子命令白名单阻断危险操作；真正的安全防线是"默认无权 + 显式准入 + 人类值守 + 即时销毁"的闭环。

---

## 5. WSL 互操作加固（可选）

### 威胁模型

在 WSL 环境中，存在已知的提权绕过路径：

```
当前问题：agent (UID 1001) 可以通过 binfmt_misc 机制：
  → 执行任意 Windows PE 文件
  → 触发 /init 解释器
  → 连接 /run/WSL/*_interop socket (权限 0777)
  → 调用 wsl.exe -u root
  → 直接提权到 root，绕过所有限制
```

### 修补目标

让互操作仅在默认用户 (UID 1000) 和 root 下可用，阻断其他用户通过 binfmt 提权。

**注意**：此修补为可选功能，setup 时提供两个子选项：
1. 是否修补（需要编译 WSL 源码，替换 `/init`）
2. 是否在 agent 提示词中添加"不要使用 wsl.exe 提权"的警告

---

## 6. 组件清单

```
not-another-sandbox/
├── cmd/
│   ├── nas-setup/          # Setup TUI（Go/Rust）
│   ├── nmux/               # CLI（relay/sodo 模式）
│   └── nmuxd/              # Daemon（relay 模式）
├── pkg/
│   ├── daemon/             # Daemon 实现
│   ├── token/              # 令牌生成与验证
│   └── tunnel/             # Agent ↔ tmux 隧道
├── skills/
│   ├── setup-guide.md      # 不安装，仅 README 引用
│   └── nas-elevate.md      # 运行时提权（setup 生成）
├── scripts/
│   └── account-setup.sh    # Agent 账户创建辅助脚本
├── docs/
│   └── design.md           # 本文档
└── README.md
```

---

## 7. 实现路线图

1. ✓ 架构设计与文档
2. Skills 编写（使用 skill-creator）
3. Setup TUI 实现
4. nmux CLI 实现（relay/sodo）
5. nmuxd daemon 实现（relay）
6. 集成测试与文档完善

---

## 8. 参考资料

- tmux 手册：生命周期管理、send-keys、capture-pane
- unix(7)：Unix domain socket 权限模型
- SO_PEERCRED：peer credential 验证
- WSL 源码：`microsoft/WSL` 仓库，`src/linux/init/` 目录

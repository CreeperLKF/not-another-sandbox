# 给人类读的速查手册（For Humans）

**简体中文** | [English](cheatsheet.en.md)

如果你平时不常折腾 Linux 多用户或 `tmux`，只需要掌握下面这两张极简速查表，就足够安全、顺手地驾驭整套流程。

---

## 1. 操作系统多账户基础

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

---

## 2. `tmux` 极简操作指南

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

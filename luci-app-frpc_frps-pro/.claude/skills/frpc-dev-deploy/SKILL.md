---
name: frpc-dev-deploy
description: Use when modifying luci-app-frpc/frps Lua or htm source in this repo and need to verify changes on the test OpenWrt device (192.168.0.187) without waiting for CI to build packages. Triggers on phrases like "部署测试"、"推到路由器"、"push to test device"、"快速验证"、"deploy and test"、"我看下效果"、"测试一下".
---

# frpc-dev-deploy

## Overview

LuCI Lua 包是**解释执行**的，无需重新编译即可生效。本 skill 通过 `scp` 把改动的 Lua/htm 源码直接推到测试设备的 `/usr/lib/lua/luci/...` 路径，清缓存并重启 web server，让改动**秒级生效**，远快于"等 CI 出包 → 下载 → opkg install"的循环。

**核心原则**：本机改 → 推 → 清缓存 → 重启服务 → 浏览器测 → 出错回滚 → 再改。

## When to Use

**使用本 skill 当**：
- 改了 `luci-app-frpc/luasrc/**/*.lua` 或 `*.htm` 想立刻在真实设备验证
- 用户问"测试一下"、"看下效果"、"部署到路由器"、"推过去"、"deploy"
- 在 LuCI 上做行为/UI 改动的迭代调试
- 想验证 Lua 改动是否触发 LuCI 报错

**不要用本 skill 当**：
- 改的是 `Makefile`、`init.d/` 脚本、`uci-defaults/`、`acl.d/json`（这些 scp 后不会自动生效，要重装包）
- 改了 `root/etc/config/frpc` 默认配置（同上）
- 改了 CI 配置 `.github/workflows/*.yml`（这属于 CI 测试，不是设备测试）
- 设备无法 SSH 联通

## Quick Reference

| 操作 | 命令 |
|---|---|
| **首次准备**（生成 SSH key + 让用户添加到设备） | 见 [首次使用](#首次使用) |
| **部署改动到测试设备** | `sh .claude/skills/frpc-dev-deploy/deploy.sh` |
| **回滚到首次备份的版本** | `sh .claude/skills/frpc-dev-deploy/rollback.sh` |
| **强制重新备份**（设备已升级或包变了） | `sh .claude/skills/frpc-dev-deploy/backup.sh --force` |
| **改设备 IP / SSH key / web server** | 编辑 `.claude/skills/frpc-dev-deploy/config.sh` 顶部环境变量 |

## Workflow

```
本地改 Lua/htm  →  sh deploy.sh  →  浏览器 Ctrl+F5  →  通过？
                                          ↓                 ↓
                                       继续迭代          sh rollback.sh
```

### 标准部署流程

```bash
sh .claude/skills/frpc-dev-deploy/deploy.sh
```

`deploy.sh` 自动完成 5 步：
1. **SSH 连通性检查**（失败立刻 bail，提示检查点）
2. **首次备份**（已存在跳过；调用 `backup.sh`）
3. **scp 推送** `config.sh` 中 `LOCAL_FILES` ↔ `REMOTE_FILES` 映射表里的所有文件
4. **清 LuCI 缓存**（`/tmp/luci-modulecache/*` 和 `/tmp/luci-indexcache*`）
5. **重启 web server + rpcd**，做健康检查

成功后输出 3 个浏览器测试 URL，引导用户 Ctrl+F5 验证。

### 部署后必做

⚠️ 重启 nginx 会**断当前浏览器 LuCI 会话**——用户需要重新登录。这是预期，不是 bug。

⚠️ 用户必须用 **Ctrl+F5（强制刷新）**，不能只 F5——否则前端 JS 可能用缓存。

## Configuration

所有可变参数集中在 [`config.sh`](./config.sh)：

```bash
TARGET_HOST="192.168.0.187"           # 设备 IP
TARGET_USER="root"
SSH_KEY="$HOME/.ssh/openwrt_frpc_dev"
WEB_SERVER="nginx"                     # Kwrt/iStoreOS=nginx, 原版OpenWrt=uhttpd
REMOTE_BACKUP_DIR="/tmp/luci_frpc_backup"
```

也支持环境变量临时覆盖：

```bash
TARGET_HOST=192.168.1.100 sh .claude/skills/frpc-dev-deploy/deploy.sh
```

**新加文件**：编辑 `config.sh` 的 `LOCAL_FILES` 和 `REMOTE_FILES` 两个列表，**逐行对应**追加。

## 首次使用

如果是新设备/新机器，按这个顺序：

### 1. 生成专用 SSH key（如果没有）

```bash
ssh-keygen -t ed25519 -f ~/.ssh/openwrt_frpc_dev -N "" -C "openwrt-frpc-dev@$(hostname)"
```

### 2. 把公钥加到设备 `authorized_keys`

让**用户**在路由器 SSH 终端执行（一次性）：

```sh
mkdir -p /etc/dropbear && cat >> /etc/dropbear/authorized_keys && chmod 0600 /etc/dropbear/authorized_keys <<'EOF'
[把 ~/.ssh/openwrt_frpc_dev.pub 的全部内容粘贴到这里]
EOF
```

### 3. 检测设备 web server

```bash
ssh -i ~/.ssh/openwrt_frpc_dev root@<IP> 'ls /etc/init.d/ | grep -iE "nginx|uhttpd|lighttpd"'
```

按输出更新 `config.sh` 的 `WEB_SERVER`。

### 4. 跑一次 deploy

```bash
sh .claude/skills/frpc-dev-deploy/deploy.sh
```

首次会自动做远端备份。

## Common Issues

| 现象 | 原因 | 解决 |
|---|---|---|
| `Permission denied (publickey)` | 公钥没加到设备 | 看 [首次使用](#首次使用) 第 2 步 |
| `No such file or directory: /etc/init.d/uhttpd` | 设备用的是 nginx 不是 uhttpd | 改 `config.sh` 的 `WEB_SERVER=nginx` |
| 推送成功但浏览器看不到改动 | 浏览器缓存 | **Ctrl+F5** 强制刷新（不是 F5） |
| 推送后 LuCI 整页报 Lua 错 | 推的代码有语法错误 | `sh rollback.sh` 秒回滚，本地修好再推 |
| `nothing to commit, working tree clean` 后 LuCI 还是老的 | LuCI modulecache 没清干净 | 手动 ssh 跑 `rm -rf /tmp/luci-modulecache/*` 后再 restart |
| 部署后浏览器登录页登不进去 | nginx 没起来 | ssh `/etc/init.d/nginx status` 看日志 |

## Real-World Impact

本 skill 形成于一次实际开发：本项目的 "代理规则复制按钮" 功能开发期间，跳过 CI 走 scp 路径，**从代码改完到浏览器验证只需 ~10 秒**，相比"push GitHub → 等 5-15 分钟 CI → 下载 ipk → opkg install → 浏览器测"快了 30-90 倍。出 bug 时 `rollback.sh` 5 秒回滚，无需重启路由器。

## Notes for Future Claude

- **不要把这个 skill 用于 init.d 脚本/Makefile 改动** —— 那些必须重装包，scp 替换没用
- **不要省略备份步骤** —— 推完出 bug 没法回滚就要电话求救用户重置
- **推完一定提示用户 Ctrl+F5**，不要让用户疑惑"为什么没变"
- **`config.sh` 是配置中心** —— 改设备/路径只动这个文件，不要在脚本里散落硬编码
- 如果 `WEB_SERVER` 错了（如 OpenWrt 原版是 uhttpd 但配的是 nginx），脚本会报 `No such file` 立刻可见

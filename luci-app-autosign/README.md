# luci-app-自动签到 (luci-app-autosign)

OpenWrt 定时自动签到插件（支持 OpenWrt 21.02 / 23.05 / 24.10 / 25.12+ 及 iStore 应用商店）。


## ✨ 核心特性

- **现代 LuCI JS 架构**：采用 OpenWrt 官方现代客户端渲染 API，界面清爽现代、响应迅速。
- **📋 智能导入抓包 / cURL 一键填单**：支持直接粘贴浏览器 (F12) 复制的 cURL (bash / cmd / PowerShell) 或原始 HTTP 报文，系统自动解析提取 URL、请求方式、请求头、Cookie 和请求载荷并自动新建任务，免除人工逐项配置的繁琐！
- **⏰ 多任务独立定时调度**：支持添加多个不同的签到任务，**每个任务均可独立设置不同的执行时间（几点几分）**，互不干扰、独立完成。
- **全局与任务级防风控**：支持随机防风控延迟（0~3600秒）与网络失败自动重试机制。
- **多任务混合配置**：
  - **HTTP(S) 请求模式**：支持配置 URL、GET/POST/PUT、自定义 Headers、Cookie、Body 以及成功匹配关键词。
  - **自定义脚本模式**：支持执行本地 Shell 脚本或命令，灵活扩展复杂打卡与自动化流程。
- **极速测试与实时日志**：页面内置「⚡ 立即测试全部任务」按钮，终端视窗实时回显每个任务的运行状态与响应摘要。
- **多渠道消息推送**：支持 PushPlus (微信)、Server酱·Turbo、Telegram Bot、Bark (iOS)、自定义 Webhook。
- **极致小巧**：纯 POSIX Shell + UCI + LuCI JS，零重型运行环境依赖，包体积仅约 20 KB。

---

## 📦 安装说明

### 1. iStore 网页端一键安装（推荐）
1. 登录路由器管理后台，进入 **iStore** -> **「手动安装」**。
2. 上传安装包 **`luci-app-autosign-1.2.0.run`**（自解压格式，100% 免疫任何包管理器差异）。
3. 安装完成后，刷新网页，在左侧导航栏 **「服务」** 中即可看到 **「定时签到」**。

### 2. 终端命令行安装
将 `.run` 文件上传至路由器后执行：
```bash
sh luci-app-autosign-1.2.0.run install
```


---

## 🗑️ 卸载说明

### 方式 1：终端一键彻底卸载（最推荐）
登录路由器终端（或通过 Web 界面「服务」->「终端」），直接复制粘贴运行以下命令即可彻底卸载并清理全部缓存残留：

```bash
/etc/init.d/autosign stop 2>/dev/null
/etc/init.d/autosign disable 2>/dev/null
sed -i '/autosign.sh/d' /etc/crontabs/root 2>/dev/null
rm -rf /usr/share/autosign
rm -f /usr/share/luci/menu.d/luci-app-autosign.json
rm -f /usr/share/rpcd/acl.d/luci-app-autosign.json
rm -rf /www/luci-static/resources/view/autosign
rm -f /etc/init.d/autosign
rm -f /etc/config/autosign
rm -f /var/log/autosign.log
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/rpcd restart 2>/dev/null
echo "✅ luci-app-autosign 已彻底卸载完成！"
```

### 方式 2：使用 `.run` 安装包卸载
如果在路由器上有下载过安装包，直接传入 `uninstall` 参数即可自动卸载：
```bash
sh luci-app-autosign-1.0.0.run uninstall
```

### 方式 3：如果通过系统包管理器安装
- **OpenWrt 25+ (APK 系统)**：
  ```bash
  apk del luci-app-autosign
  ```
- **OpenWrt 21/23/24 (OPKG 系统)**：
  ```bash
  opkg remove luci-app-autosign
  ```

---

## 🛠️ 文件结构

```text
luci-app-autosign/
├── Makefile                                # OpenWrt 源码编译规则
├── root/
│   ├── etc/
│   │   ├── config/autosign                 # UCI 配置文件模板
│   │   └── init.d/autosign                 # Procd 系统服务与 Crontab 调度守护
│   ├── usr/share/
│   │   ├── autosign/autosign.sh            # 核心签到与推送 Shell 引擎
│   │   ├── luci/menu.d/...                 # LuCI 现代导航菜单注册
│   │   └── rpcd/acl.d/...                  # LuCI RPCD 权限控制
│   └── www/luci-static/resources/view/
│       └── autosign/index.js               # 现代 LuCI JS 响应式前端视图
└── control/                                # IPK/APK 元数据与钩子脚本
```

---

## 📄 开源协议

本项目采用 [Apache-2.0](LICENSE) 协议开源。

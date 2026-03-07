# Easy MWAN3 Configurator (v2.1.1)

> **极简、强大、智能的 OpenWrt 多拨负载均衡配置工具**

![Version](https://img.shields.io/badge/version-2.1.1-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![OpenWrt](https://img.shields.io/badge/OpenWrt-21.02+-orange)

## ⚠️ 重要提示

**本插件依赖 mwan3，而 mwan3 仅支持 iptables/fw3，不支持 nftables/fw4。**

如果你的 OpenWrt 使用 firewall4 (fw4)，此插件将无法正常工作。请使用以下替代方案：
- **策略路由 (pbr)**: 支持 nftables
- **降级到 fw3**: 安装 iptables 和 firewall3

## ✨ 核心特性

### 1. 🚀 混合策略引擎
- **全局负载均衡**: 所有流量默认在多线路间分配
- **设备特定策略**: 为特定设备指定固定线路
- **智能故障切换**: 线路故障自动切换

### 2. 🔧 简化配置
- **一键式操作**: 告别繁琐的手动配置
- **Web 界面**: LuCI 图形化管理
- **智能检测**: 自动识别 WAN 接口

### 3. 🛡️ 安全可靠
- **配置验证**: 自动检查配置有效性
- **状态监控**: 实时显示接口状态
- **日志记录**: 完整的操作日志

## 📦 安装

### 方法 1: opkg 安装

```bash
# 下载 ipk 包
cd /tmp
wget https://github.com/pengcong226/luci-app-easy-mwan3/releases/download/v2.1.1/luci-app-easy-mwan3_2.1.1_all.ipk

# 安装
opkg install luci-app-easy-mwan3_2.1.1_all.ipk

# 安装中文翻译
opkg install luci-i18n-easy-mwan3-zh-cn

# 重启 LuCI
/etc/init.d/uhttpd restart
```

### 方法 2: 从源码编译

```bash
# 克隆仓库
git clone https://github.com/pengcong226/luci-app-easy-mwan3.git

# 复制到 OpenWrt 源码
cp -r luci-app-easy-mwan3 openwrt/feeds/luci/applications/

# 编译
cd openwrt
make package/luci-app-easy-mwan3/compile
```

## 🚀 快速开始

### 1. 访问界面

浏览器访问: `http://路由器IP/cgi-bin/luci/admin/network/easy_mwan3`

### 2. 基本配置

1. **启用服务**: 勾选"启用 Easy MWAN3"
2. **选择模式**: 
   - **均衡模式**: 流量分配到所有接口
   - **主备模式**: 主接口优先，故障时切换备份
3. **选择接口**: 勾选参与负载均衡的 WAN 接口
4. **保存应用**: 点击"保存并应用"

### 3. 高级策略

为特定设备配置固定线路：

1. 在"高级设备策略"区域点击"添加"
2. 输入设备 IP 或从 DHCP 租约选择
3. 选择策略（强制走 WAN/WAN2）
4. 保存并应用

## 📖 使用说明

### 命令行工具

```bash
# 应用配置
/usr/bin/easy_mwan3_apply.sh

# 查看状态
/usr/bin/easy_mwan3_status.sh json

# 验证配置
/usr/bin/easy_mwan3_validate.sh config

# 运行测试
/usr/bin/easy_mwan3_test.sh

# 查看日志
logread | grep easy_mwan3
```

### 配置文件

配置文件位置: `/etc/config/easy_mwan3`

```bash
config global 'global'
    option enabled '1'
    option mode 'balance'
    list members 'wan'
    list members 'wan2'

config rule
    option src_ip '192.168.1.100'
    option policy 'wan_only'
    option comment 'Gaming PC'
```

### 手动控制

```bash
# 启用服务
uci set easy_mwan3.global.enabled=1
uci commit easy_mwan3
/usr/bin/easy_mwan3_apply.sh

# 禁用服务
uci set easy_mwan3.global.enabled=0
uci commit easy_mwan3
/usr/bin/easy_mwan3_apply.sh
```

## 🔍 故障排查

### 测试脚本

运行测试脚本诊断问题：

```bash
/usr/bin/easy_mwan3_test.sh
```

### 常见问题

**Q: 配置不生效？**

```bash
# 手动应用配置
/usr/bin/easy_mwan3_apply.sh

# 重启 MWAN3
/etc/init.d/mwan3 restart

# 检查日志
logread | grep -E "easy_mwan3|mwan3"
```

**Q: 接口显示离线？**

```bash
# 检查接口状态
ubus call network.interface.wan status

# 检查 MWAN3 配置
uci show mwan3
```

**Q: fw4 不兼容？**

```bash
# 检查防火墙版本
uci get firewall.@defaults[0].name

# 如果是 fw4，请使用 pbr 替代
opkg install pbr
```

## 📚 文档

- [测试指南](TESTING.md) - 完整的测试和故障排查指南
- [变更日志](CHANGELOG.md) - 版本更新历史

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

MIT License

## 🙏 致谢

- OpenWrt 项目
- MWAN3 项目
- LuCI 项目

## 📝 更新日志

### v2.1.1 (2026-03-07)

**安全修复**
- 修复 XSS 漏洞
- 修复命令注入风险

**新增功能**
- 配置转换逻辑
- 混合策略引擎
- 状态检测功能
- 配置验证
- 自动化测试

**改进**
- fw3/fw4 兼容性检测
- 改进接口识别
- 完善错误处理

详细更新日志请查看 [CHANGELOG.md](CHANGELOG.md)

---

**Created with ❤️ by PengCong226**

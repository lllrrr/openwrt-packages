# luci-app-backup

# LuCI 智能备份恢复插件

OpenWrt 系统的智能备份恢复插件，支持任务化备份、GPG加密备份、批量恢复等功能。

## 功能特点

- 多任务备份管理
- 支持文件和文件夹备份
- GPG AES256 加密支持
- 批量恢复功能
- 可视化的文件选择界面
- 备份文件自动管理

## 依赖

- jsonfilter
- gnupg
- luci-lib-jsonc

## 安装

```bash
opkg update
opkg install luci-app-backup

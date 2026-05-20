Only Simplified Chinese.
仅中文简体，主要是懒~

用的 lua API，兼容旧版系统

含 ipk 安装包 和 apk 安装包。到 Release 页面下载。

注意：不包含二进制可执行文件，可到下面链接下载：
https://github.com/fatedier/frp/releases
按架构下载，解压即获得二进制文件，传到设备某个目录，在 luci 界面指定这个路径即可。

toml 配置文件格式，必须frp版本不低于v0.52.0

对于apk包跳过证书安装命令
apk add --allow-untrusted luci-app-frpc.apk

![image](https://github.com/superzjg/luci-app-frpc_frps/blob/main/luci_frp.jpeg)

## 多实例

本版本支持同时连接多个 frps 服务器。在 LuCI 中：

1. 进入「服务 → frpc → 服务器」，每个服务器条目就是一个独立 frpc 实例；
2. 「启用此实例」开关 + 服务器列表行内「操作」下拉控制单实例启停 / 重启；
3. 「规则」页可按服务器筛选与批量改归属（`server_id` 字段）；
4. 状态栏与列表实时显示每实例的运行 / proxy 在线数；
5. 每实例独立 admin Dashboard（默认 7400 起自动分配端口）。

升级说明：从单实例版本升级时，迁移脚本会自动把 `main` 中的连接字段下沉到 `server` section，并给所有 rule 写入 `server_id`，无需手动配置。

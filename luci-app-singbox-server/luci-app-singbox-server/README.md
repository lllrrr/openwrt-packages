# luci-app-singbox-server

## V7 说明

- `PKG_RELEASE:=0`。
- `LUCI_DEPENDS:=+luci-base +luci-compat`，不依赖 sing-box 包。
- 恢复原始 sing-box 命令顺序：`sing-box check -c xxx.json`、`sing-box run -c xxx.json`。
- 状态检测恢复为匹配：`sing-box run -c /tmp/etc/singbox_server/xxx.json`。
- 保留 V6 的 JSON 生成修复、TLS/Reality 校验、Mux 输出和日志修复。


OpenWrt 25.12 sing-box 多实例服务端 LuCI 插件。

## 修复重点

- 生成脚本显式加载 `/lib/functions.sh`，避免 `config_get/config_load` 在独立脚本中不可用。
- 按要求恢复原始命令顺序：`sing-box check -c <config>`、`sing-box run -c <config>`。
- 协议与传输方式自动规范化，避免生成 `inbounds:[{}]`。
- VMess/VLESS/Trojan/Hysteria2/TUIC 自动生成 UUID/密码。
- procd 多实例启动。

## 编译

```sh
cp -r luci-app-singbox-server openwrt/package/
cd openwrt
make package/luci-app-singbox-server/compile V=s
```

## 运行

```sh
/etc/init.d/singbox_server enable
/etc/init.d/singbox_server restart
cat /tmp/log/singbox_server.log
cat /tmp/etc/singbox_server/*.json
sing-box check -c /tmp/etc/singbox_server/*.json
```


## V6 修复

- 修复 V5 生成 TLS / WebSocket / gRPC 时多输出 `}` 导致 JSON 非法的问题。
- 启用普通 TLS 时增加证书路径和私钥路径校验。

# luci-app-settings

在 LuCI 中直接查看/编辑常用 UCI 配置文件(`/etc/config/network`、`dhcp`、
`firewall`、`system`)的原始内容,保存后可一键使更改生效;并支持通过
「添加自定义文件」按钮把 `/etc` 下的任意文件加入编辑列表。

适用于 OpenWrt 24.10 / 25.12(纯 JavaScript LuCI,包体系结构无关,`apk` / `opkg` 均可)。

## 功能

- 「系统 → 高级设置」页面(英文界面为 Configuration Files),标签页方式展示各配置文件的原始文本
- 按钮顺序:**保存并应用**(写入后执行 `/sbin/reload_config`,由 procd 自动
  重载配置发生变化的服务)/ **保存**(仅写入文件)/ **复位**(放弃未保存的
  修改,重新载入磁盘上的当前文件内容)
- 保存 `/etc/config/*` 前先在 `/tmp` 中用 `uci -c … show` 做语法预校验,
  语法错误会拒绝写入并提示出错位置,避免写坏配置
- 基于 CodeMirror 6 的编辑器(随包分发约 380KB,离线可用;加载失败时自动
  回退为普通文本框):UCI / JSON / shell 语法高亮、行号、括号匹配、
  编辑器内搜索(Ctrl-F)、暗色主题自适应;JSON 文件实时标红语法错误且
  保存前拦截,UCI 保存校验失败时在编辑器中标红出错行并跳转
- 自定义文件:路径限于 `/etc` 下(由 ACL 限制,可自行放宽,见下),
  可为每个文件指定「应用时重启的 init.d 服务」,留空则执行 `reload_config`;
  添加时会自动查找 `/etc/init.d/` 下的匹配脚本(按文件名、去扩展名、
  父目录名匹配,如 `dnsmasq.conf` → `dnsmasq`、`/etc/sing-box/config.json`
  → `sing-box`),找到时标注并自动填入服务名;列表中未配置服务的自定义文件
  如存在匹配的 init.d 脚本,也会在页面上标注
- 自定义文件列表保存在 `/etc/luci-app-settings.json`
- 自带简体中文翻译(`luci-i18n-settings-zh-hans`)

## 编译(OpenWrt SDK)

```sh
# 以 25.12.5 x86_64 SDK 为例
tar --zstd -xf openwrt-sdk-25.12.5-x86-64_*.tar.zst && cd openwrt-sdk-*
./scripts/feeds update base luci
./scripts/feeds install -a -p luci
cp -r /path/to/luci-app-settings package/
make defconfig
make package/luci-app-settings/compile V=s
# 产物: bin/packages/*/base/luci-app-settings-*.apk 及 luci-i18n-settings-zh-hans-*.apk
```

## 重新打包 CodeMirror(仅在升级 CM6 或改动编辑器依赖时需要)

`htdocs/luci-static/resources/settings/cm6.js` 是 esbuild 打包产物,已提交进
仓库,日常编译 apk 不需要 npm。需要重建时(任意平台,需 node ≥18):

```sh
cd vendor && npm install && npm run build
```

改动 cm6.js 后请把 `editor.js` 中 `loadCM6()` 的 `?v=` 版本号 +1,
避免浏览器使用旧缓存。

## 安装

```sh
# OpenWrt 25.12+ (apk),--allow-untrusted 用于本地未签名包
apk add --allow-untrusted ./luci-app-settings-*.apk
apk add --allow-untrusted ./luci-i18n-settings-zh-cn-*.apk
# OpenWrt 24.10 及更早 (opkg)
# opkg install ./luci-app-settings-*.ipk
```

安装时包的 post-install 脚本会自动清理 LuCI 缓存并执行 `rpcd reload`,
无需手动重启 rpcd。浏览器强制刷新(Ctrl+F5)后,「系统」菜单下即可看到
「高级设置」(英文界面为 Configuration Files)。

## 卸载

```sh
apk del luci-app-settings luci-i18n-settings-zh-cn
```

卸载脚本会自动清理 LuCI 缓存、`/tmp/luci-app-settings/` 临时目录并 `rpcd reload`。
自定义文件列表 `/etc/luci-app-settings.json` 会**保留**(重装后列表恢复);
如需彻底清除:`rm -f /etc/luci-app-settings.json`。

## 放宽自定义文件路径限制

默认 ACL 只允许读写 `/etc` 下的文件。如需编辑其他位置(如 `/root`、`/usr`),
编辑 `/usr/share/rpcd/acl.d/luci-app-settings.json`,在 `read.file` /
`write.file` 中追加相应的路径模式(如 `"/root/*": [ "read" ]`),同时放宽
`htdocs/luci-static/resources/view/settings/editor.js` 中 `handleAddSave`
的路径校验,然后执行 `/etc/init.d/rpcd restart`。

## 注意事项

- 文件通过 ubus `file` 接口读写,不适合编辑超大文件(数百 KB 以上)
- `reload_config` 只对注册了 procd 配置触发器的服务生效;个别服务
  (如部分自定义脚本)需要用「重启 init.d 服务」方式应用

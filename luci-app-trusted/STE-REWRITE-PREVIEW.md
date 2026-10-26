# 界面文本 STE 重写预览（中英双语润色版）

本文件是文本底稿。1.3.0 起，中文正文以这里为准，落到了 `po/zh_Hans/trusted.po` 和
`files/usr/share/trusted/i18n/zh_cn.sh`；英文是 msgid，写在 `main.js` 和 `en.sh` 里。

## 改写规则

| 规则   | 做法                                                                      |
| ---- | ----------------------------------------------------------------------- |
| 句长   | 陈述句不超过 25 词。操作句不超过 20 词                                                 |
| 语态   | 用主动语态。不用「被」「由」                                                          |
| 时态   | 只用现在、过去、将来                                                              |
| 一词一义 | 白名单 = whitelist。设备 = device。网页 = web page。终端 = web terminal。网段 = subnet |
| 名词堆叠 | 连续名词不超过 3 个                                                             |
| 提示   | 风险提示用 Caution / WARNING 开头。补充说明用 Note 开头                                |
| 顺序   | 先说做什么。再说结果。最后说怎么做                                                       |

## 术语对照

| 中文     | 英文                 | 说明                           |
| ------ | ------------------ | ---------------------------- |
| 白名单    | whitelist          | 全文统一。不用 list、allowlist       |
| 设备     | device             | 替换原文「白名单中的 IP」。地址属于设备        |
| 管理页面   | LuCI web page      | 不用 interface、panel           |
| Web 终端 | web terminal       | 小写开头                         |
| 免密     | without a password | 不用 password-free、no-password |
| 网段     | subnet             | 不用 network、range             |
| 生效     | active             | 不用 effective                 |

## 一、页面文本

| 编号 | 原文                                                                                     | 英文（STE）                                                                                                                                                                                                                                      | 中文回译                                                                                        |
| -- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| 1  | Trusted 免密                                                                             | Trusted Access                                                                                                                                                                                                                               | Trusted 免密                                                                                  |
| 2  | 白名单中的 IP 访问 LuCI 管理页面、终端或通过 SSH 连接时无需输入账号密码。                                           | Devices in the whitelist can open the LuCI web page, the web terminal, and SSH without a password.                                                                                                                                           | 白名单中的设备可以免密开启 LuCI 管理页面、Web 终端和 SSH。                                                        |
| 3  | 支持单个 IP（10.3.2.5）或整个网段（10.3.2.0/24），仅限 IPv4；127.0.0.1 始终受信任。                           | You can add one IP address (10.3.2.5) or one subnet (10.3.2.0/24). Only IPv4 is supported. The router always trusts 127.0.0.1.                                                                                                               | 您可添加一个 IP 地址（10.3.2.5）或一个网段（10.3.2.0/24）。仅支持 IPv4。路由器始终信任 127.0.0.1。                        |
| 4  | 启用后白名单不能为空，至少要有一个地址。                                                                   | The whitelist must contain at least one address. The router does not accept an empty whitelist.                                                                                                                                              | 白名单必须至少包含一个地址。路由器不接受空的白名单。                                                                  |
| 5  | 白名单                                                                                    | Whitelist                                                                                                                                                                                                                                    | 白名单                                                                                         |
| 6  | 启用                                                                                     | Enable                                                                                                                                                                                                                                       | 启用                                                                                          |
| 7  | IP 地址                                                                                  | IP address                                                                                                                                                                                                                                   | IP 地址                                                                                       |
| 8  | 受信任的 IP 或网段，例如 10.3.2.5 或 10.3.2.0/24                                                  | Enter an IP address or a subnet that you trust. Example: 10.3.2.5 or 10.3.2.0/24.                                                                                                                                                    | 请输入您信任的 IP 地址或网段。示例：10.3.2.5 或 10.3.2.0/24。                                                 |
| 9  | 请把你自己当前使用的地址加进去。                                                                       | Add the address that your device uses now.                                                                                                                                                                                                   | 请添加您的设备当前使用的地址。                                                                             |
| 10 | Web 终端免密                                                                               | Web terminal without a password                                                                                                                                                                                                              | Web 终端免密                                                                                    |
| 11 | 开启后，白名单 IP 打开 Web 终端直接进入 root shell，无需密码。                                              | If you enable this option, whitelisted devices can log in to the web terminal without a password.                                                                                                                                            | 如果您启用此选项，白名单设备将可以免密登录Web终端。                                                                 |
| 12 | 只作用于白名单：白名单以外的设备仍可照常在终端用账号密码登录。                                                        | This option applies to whitelisted devices only. Devices outside the whitelist can still log in to the web terminal with a user name and a password.                                                                                          | 此选项只作用于白名单内的设备。白名单外的设备仍可通过用户名和密码登录 Web 终端。                                                  |
| 13 | SSH 免密                                                                                 | SSH without a password                                                                                                                                                                                                                       | SSH 免密                                                                                      |
| 14 | 开启后，白名单 IP 执行 ssh trusted@路由器地址 直接进入 root shell，无需密码。                                  | If you enable this option, a whitelisted device runs ssh trusted@router-address and reaches a root shell without a login.                                                                                                                    | 如果您启用此选项，白名单设备通过执行 ssh trusted@路由器地址 即进入 root shell，而无需登录。                                  |
| 15 | 只作用于白名单：白名单以外的设备仍可照常在 22 端口用账号密码或密钥登录。                                                 | This option applies to whitelisted devices only. Devices outside the whitelist can still log in on port 22 with a password or a key.                                                                                                         | 此选项只作用于白名单内的设备。白名单外的设备仍可在 22 端口用密码或密钥登录。                                                    |
| 16 | 禁止白名单外设备登录                                                                             | Block devices that are not in the whitelist                                                                                                                                                                                                  | 禁止白名单外设备登录                                                                                  |
| 17 | 开启后，白名单以外的设备被完全阻止访问管理页面和终端（不再显示登录页）；关闭时这些设备可以照常用账号密码登录。                                | If you enable this option, the router blocks devices outside the whitelist from the LuCI web page and the web terminal.                                                                                                                       | 如果您启用此选项，白名单外的设备将会被阻止访问LuCI管理页面和Web终端。                                                      |
| 18 | 本选项独立于上面两项，不影响白名单内的免密。                                                                 | This option is independent of the two options above. It does not change how whitelisted devices get in without a password.                                                                                                                   | 此选项独立于上面两个选项。它不改变白名单设备免密进入的方式。                                                              |
| 19 | 注意：白名单里必须包含你自己的地址，否则保存后你也打不开这个页面。                                                      | Caution: the whitelist must contain your own address. If it does not, you cannot open this page after you save the configuration.                                                                                                            | 注意：白名单必须包含您自己的地址。否则保存配置后您将无法打开此页面。                                                          |
| 20 | 开启前请确认你知道 root 密码，或已经装好可用的 SSH 密钥。被挡住后只能用 SSH 登录，执行 trusted deny off 解除。没有 SSH 就只能接串口。 | Before you enable this option, make sure that you know the root password. Also make sure that you have a valid SSH key. If the router blocks you, log in with SSH and run trusted deny off. If SSH is not available, use the serial console. | 启用此选项之前，请确认您知道 root 密码，并备有可用的 SSH 密钥。若被挡住，请用 SSH 登录并执行 trusted deny off。若 SSH 不可用，请使用串口控制台。 |

## 二、输入校验提示

| 编号 | 原文                                                        | 英文（STE）                                                                                                                                                                      | 中文回译                                                         |
| -- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| 21 | 只支持 IPv4 地址或网段，例如 10.3.2.5 或 10.3.2.0/24                  | Enter an IPv4 address or a subnet. Example: 10.3.2.5 or 10.3.2.0/24.                                                                                                         | 请输入 IPv4 地址或网段。示例：10.3.2.5 或 10.3.2.0/24。                    |
| 22 | 每段不要有多余的前导零，例如应填 10.3.2.8 而不是 10.3.2.08                   | Remove the leading zero from each part. Example: type 10.3.2.8, not 10.3.2.08.                                                                                               | 请去掉每一段的前导零。示例：填 10.3.2.8，不要填 10.3.2.08。                      |
| 23 | 每段的数值必须在 0-255 之间                                         | Each part must be a number from 0 to 255.                                                                                                                                    | 每一段必须是 0 到 255 的数字。                                          |
| 24 | 网段前缀必须在 0-32 之间                                           | The subnet prefix must be a number from 0 to 32.                                                                                                                             | 网段前缀必须是 0 到 32 的数字。                                          |
| 25 | 白名单是空的。请先在「IP 地址」里加入你自己的地址，再开启本选项。否则保存后防火墙会挡住你，管理页面就打不开了。 | The whitelist is empty. Add your own address in "IP address" first. Then enable this option. If you save now, the firewall blocks your device and you cannot open this page. | 白名单为空。请先在「IP 地址」中加入您自己的地址，再启用此选项。若现在保存，防火墙会挡住您的设备，您将无法打开此页面。 |

## 三、菜单标题

| 编号 | 原文         | 英文（STE）        | 中文回译       |
| -- | ---------- | -------------- | ---------- |
| 26 | Trusted 免密 | Trusted Access | Trusted 免密 |

## 四、错误页

| 编号 | 原文                                                             | 英文（STE）                                                            | 中文回译                          |
| -- | -------------------------------------------------------------- | ------------------------------------------------------------------ | ----------------------------- |
| 27 | Access denied by Trusted: this device is not in the whitelist. | Trusted blocked this request. This device is not in the whitelist. | Trusted 已拦截此请求。此设备不在白名单中。     |
| 28 | luci-app-trusted: stock CGI is missing.                        | Error: the LuCI CGI file is missing. Install the package again.    | 错误：LuCI 的 CGI 文件缺失。请重新安装本安装包。 |

## 五、命令行帮助

| 原文                                                    | 英文（STE）                                                                                          | 中文回译                                                 |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------- |
| 用法: trusted <命令> [参数]                                 | Usage: trusted <command> [argument]                                                              | 用法：trusted <命令> [参数]                                 |
| status 显示开关状态和当前生效的白名单                                | status — Show the switch states and the active whitelist                                         | status — 显示开关状态与当前生效的白名单                             |
| add <地址> [地址...] 添加 IPv4 地址或网段，立即生效                   | add <address>... — Add one or more IPv4 addresses or subnets. The change applies immediately.    | add <地址>... — 添加一个或多个 IPv4 地址或网段。改动立即生效。             |
| del <地址> [地址...] 删除 IPv4 地址或网段，立即生效                   | del <address>... — Delete one or more IPv4 addresses or subnets. The change applies immediately. | del <地址>... — 删除一个或多个 IPv4 地址或网段。改动立即生效。             |
| deny on|off 开关「禁止白名单外设备登录」                            | deny on|off — Enable or disable "Block devices that are not in the whitelist"                    | deny on|off — 开启或关闭「禁止白名单外设备登录」                      |
| 地址格式: a.b.c.d 或 a.b.c.d/nn，例如 10.3.2.5 或 10.3.2.0/24。 | Address format: a.b.c.d or a.b.c.d/nn. Example: 10.3.2.5 or 10.3.2.0/24.                         | 地址格式：a.b.c.d 或 a.b.c.d/nn。示例：10.3.2.5 或 10.3.2.0/24。 |

## 六、命令行报错

| 原文                                            | 英文（STE）                                                                              | 中文回译                                               |
| --------------------------------------------- | ------------------------------------------------------------------------------------ | -------------------------------------------------- |
| 缺少 $LIB，无法校验地址格式                              | Cannot find $LIB. Address validation is not available.                               | 找不到 $LIB。地址校验功能不可用。                                |
| $LIB 损坏，无法校验地址格式                              | $LIB is damaged. Address validation is not available.                                | $LIB 已损坏。地址校验功能不可用。                                |
| add 需要一个地址，例如: trusted add 10.3.2.5           | The add command needs one address. Example: trusted add 10.3.2.5                     | add 命令需要一个地址。示例：trusted add 10.3.2.5               |
| 已拒绝 '$a'：只接受 IPv4 或网段（10.3.2.5 或 10.3.2.0/24） | Rejected '$a'. Use an IPv4 address or a subnet, for example 10.3.2.5 or 10.3.2.0/24. | 已拒绝 '$a'。请使用 IPv4 地址或网段，例如 10.3.2.5 或 10.3.2.0/24。 |
| 已存在 '$a'                                      | '$a' is already in the whitelist.                                                    | '$a' 已在白名单中。                                       |
| 写入失败 '$a'                                     | Cannot write '$a' to the configuration.                                              | 无法将 '$a' 写入配置。                                     |
| del 需要一个地址，例如: trusted del 10.3.2.5           | The del command needs one address. Example: trusted del 10.3.2.5                     | del 命令需要一个地址。示例：trusted del 10.3.2.5               |
| 不在白名单里 '$a'                                   | '$a' is not in the whitelist.                                                        | '$a' 不在白名单中。                                       |
| 删除失败 '$a'                                     | Cannot delete '$a'.                                                                  | 无法删除 '$a'。                                         |
| deny 需要 on 或 off                              | The deny command needs on or off.                                                    | deny 命令需要 on 或 off。                                |
| 未知命令: $1                                      | Unknown command: $1                                                                  | 未知命令：$1                                            |
| uci commit 失败                                 | The uci commit command failed.                                                       | uci commit 命令失败。                                   |
| 写入失败                                          | Cannot write the setting.                                                            | 无法写入该设置。                                           |

## 七、命令行结果

| 原文                                        | 英文（STE）                                                                                               | 中文回译                                      |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| 已添加 $added 条                              | Added $added entries.                                                                                 | 已添加 $added 条。                             |
| 已删除 $removed 条                            | Deleted $removed entries.                                                                             | 已删除 $removed 条。                           |
| 当前生效: ...                                 | Active whitelist: ...                                                                                 | 当前生效：...                                  |
| 注意，插件当前未启用，白名单暂不生效                        | Note: the plugin is disabled. The whitelist has no effect.                                            | 注意：插件未启用，白名单暂不生效。                         |
| 已写入配置，但插件没有生成生效白名单，请查看 logread -e trusted | The configuration is saved, but the plugin did not build an active whitelist. Run logread -e trusted. | 配置已保存，但插件未生成生效白名单。请执行 logread -e trusted。 |
| deny_others=$v                            | deny_others=$v                                                                                        | deny_others=$v                            |

## 八、命令行警告

| 原文                                            | 英文（STE）                                                                                                  | 中文回译                                                      |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| 警告: 已禁止白名单外设备，但生效白名单只有 127.0.0.1。             | WARNING: this option blocks other devices, but the active whitelist contains 127.0.0.1 only.             | 警告：此选项会阻止其他设备，但生效白名单仅有 127.0.0.1。                         |
| 局域网内所有设备都无法打开管理页面。用 trusted add <地址> 修复。      | No device on the LAN can open the web page. Run trusted add <address> to correct this.                   | 局域网内无任何设备能打开网页。请执行 trusted add <地址> 修复。                   |
| 警告: 白名单已空且禁止白名单外设备，管理页面将不可访问                  | WARNING: the whitelist is empty and this option is on. The web page will be inaccessible.                | 警告：白名单为空，且此选项已开启，网页将无法访问。                                 |
| 用 trusted deny off 解除，或 trusted add <地址> 加回来。 | Run trusted deny off to disable the option. Or run trusted add <address> to add your address again.      | 请执行 trusted deny off 关闭此选项，或执行 trusted add <地址> 重新加入您的地址。 |
| 警告: 白名单只有 127.0.0.1，所有局域网设备都将失去管理页面。          | WARNING: the whitelist contains 127.0.0.1 only. All devices on the LAN will lose access to the web page. | 警告：白名单仅有 127.0.0.1。局域网内所有设备都将失去网页访问。                      |
| 用 trusted add <地址> 把自己加进去。                    | Run trusted add <address> to add your own address.                                                       | 请执行 trusted add <地址> 加入您自己的地址。                            |

## 九、status 字段标签

| 原文           | 英文（STE）       | 中文回译    |
| ------------ | ------------- | ------- |
| enabled      | plugin:       | 插件：     |
| term_enabled | web terminal: | Web 终端： |
| ssh_enabled  | ssh:          | SSH：    |
| deny_others  | block others: | 禁止其他设备： |
| configured   | in config:    | 配置中：    |
| effective    | active:       | 生效：     |

## 需要你确认的四处改动

STE 要求一词一义、主动语态，因此有几处不能照原文直译。

| 项    | 改动                           | 原因                             |
| ---- | ---------------------------- | ------------------------------ |
| 主体词  | 「白名单中的 IP」→「白名单中的设备」（device） | 地址属于设备。防火墙按设备地址判定              |
| 免密   | 「免密」→ without a password     | password-free 是复合词，STE 优先用完整短语 |
| 管理页面 | 「管理页面」→ LuCI web page        | 原文有多种叫法。统一成一个                  |
| 错误页  | 27、28 改成整句，28 补「重新安装」动作      | 原文只有现象。用户需要下一步动作               |

## 十、落地位置（1.3.0）

| 编号段 | 落地文件 | 语言 |
|---|---|---|
| 1–25 | `files/www/luci-static/resources/view/trusted/main.js`（英文 msgid）<br>`po/zh_Hans/trusted.po`（中文） | 随 LuCI 语言 |
| 26 | `files/usr/share/luci/menu.d/luci-app-trusted.json`（`Trusted Access`）<br>由同一份 `.lmo` 翻成中文 | 随 LuCI 语言 |
| 27–28 | `files/usr/share/trusted/i18n/{en,zh_cn}.sh` | 随 LuCI 语言 |
| 命令行 | 同上两份 `.sh` | 随 LuCI 语言 |

## 十一、两处建议修改

| 编号 | 现状 | 建议 | 理由 |
|---|---|---|---|
| 14 | 中文「即进入 root shell，而无需登录」 | 「即进入 root shell，无需密码」 | `ssh trusted@地址` 仍然完成一次登录，只是密码为空。说「无需登录」与实际行为不符 |
| 18 | 中文「不改变白名单设备免密进入的方式」 | 保持 | 无问题，列出仅为对照 |

编号 14 若要改，英文同步改成 `...and reaches a root shell without a password.`。

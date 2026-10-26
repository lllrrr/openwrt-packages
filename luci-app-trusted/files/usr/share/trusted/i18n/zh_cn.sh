# 简体中文消息表。键名必须与 en.sh 完全一致。
#
# 只在 LuCI 语言为中文时加载。修改这里的文本前，先改 en.sh，
# 两者用同一套键名，缺键时终端会直接显示键名。

T_usage="用法：trusted <命令> [参数]

  status                 显示开关状态与当前生效的白名单
  add <地址>...          添加 IPv4 地址或网段，立即生效
  del <地址>...          删除 IPv4 地址或网段，立即生效
  deny on|off            开启或关闭「禁止白名单外设备登录」

地址格式：a.b.c.d 或 a.b.c.d/nn。示例：10.3.2.5 或 10.3.2.0/24。"

T_err_no_lib="找不到 %s。地址校验功能不可用。"
T_err_bad_lib="%s 已损坏。地址校验功能不可用。"

T_err_add_noarg="add 命令需要一个地址。示例：trusted add 10.3.2.5"
T_err_del_noarg="del 命令需要一个地址。示例：trusted del 10.3.2.5"
T_err_deny_arg="deny 命令需要 on 或 off。"
T_err_unknown="未知命令：%s"

T_err_reject="已拒绝 '%s'。请使用 IPv4 地址或网段，例如 10.3.2.5 或 10.3.2.0/24。"
T_err_write="无法将 '%s' 写入配置。"
T_err_del_fail="无法删除 '%s'。"
T_err_commit="uci commit 命令失败。"
T_err_set="无法写入该设置。"
T_err_no_active="配置已保存，但插件未生成生效白名单。请执行 logread -e trusted。"

T_info_exists="'%s' 已在白名单中。"
T_info_notin="'%s' 不在白名单中。"

T_ok_added="白名单已更新。新增 %s 条。"
T_ok_deleted="白名单已更新。删除 %s 条。"
T_ok_active="当前生效：%s"
T_ok_deny="deny_others=%s"
T_note_disabled="注意：插件未启用，白名单暂不生效。"

T_warn_deny_short="警告：此选项会阻止其他设备，但生效白名单仅有 127.0.0.1。"
T_warn_no_page="局域网内无任何设备能打开网页。请执行 trusted add <地址> 修复。"
T_warn_empty="警告：白名单为空，且此选项已开启，网页将无法访问。"
T_hint_undo="请执行 trusted deny off 关闭此选项，或执行 trusted add <地址> 重新加入您的地址。"
T_warn_lose="警告：白名单仅有 127.0.0.1。局域网内所有设备都将失去网页访问。"
T_hint_add="请执行 trusted add <地址> 加入您自己的地址。"

T_lbl_plugin="插件"
T_lbl_term="Web 终端"
T_lbl_ssh="SSH"
T_lbl_deny="禁止其他设备"
T_lbl_cfg="配置中"
T_lbl_active="生效"
T_empty="<空>"

T_http_403="Trusted 已拦截此请求。此设备不在白名单中。"
T_http_500="错误：LuCI 的 CGI 文件缺失。请重新安装本安装包。"

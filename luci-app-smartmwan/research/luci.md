# LuCI / rpcd / ucode 审计要点（无 Lua 的实现依据）

> **来源与可信度声明**：本文件是把早前一次针对 OpenWrt 25.12 上游源码的审计结论压缩成笔记
> （审计在另一会话中完成，当时能读到 `luci-base`、`rpcd`、`uhttpd` 的实际文件）。
> **打包（M9）之前必须在真实 SDK 里逐条复核**，尤其是文件路径与 JSON schema 字段名。
> 与 `docs/REQUIREMENTS.md` §10 的外部来源引用配合阅读。

## 1. 25.12 的 LuCI 已经没有 Lua 运行时依赖

* `luci-base` 不再携带 `luasrc/`，其依赖列表里没有 Lua 包；
* Lua 支持由**独立包** `luci-lua-runtime` 提供。⇒ 本插件的 Makefile 若声明该依赖，
  `scripts/no-lua-check.sh` 会直接判失败（它同时扫文件、`require("luci.*")` 内容、Makefile 依赖三个维度）。

## 2. 纯 JS 视图的文件布局

| 用途 | 路径 |
|---|---|
| 视图模块 | `htdocs/luci-static/resources/view/smartmwan/<tab>.js` |
| 样式 | `htdocs/luci-static/resources/smartmwan/smartmwan.css` |
| 菜单定义 | `root/usr/share/luci/menu.d/luci-app-smartmwan.json` |
| ACL 定义 | `root/usr/share/rpcd/acl.d/luci-app-smartmwan.json` |
| RPC 桥 | `root/usr/share/rpcd/ucode/smartmwan.uc` |

注意路径易错点：ACL 是 `usr/share/rpcd/acl.d`，**不是** `usr/share/luci/rpcd/acl.d`
（本仓库早前就误建过后者并删除）。

## 3. 视图写法（无 Lua 的原生 JS API）

```js
"use strict";
"require rpc";
"require view";
"require form";

return view.extend({
    load: function () {
        return rpc.declare({
            object: "smartmwan",
            method: "getStatus",
            expect: ["data"]
        })();
    },

    render: function (ctx, data) {
        // 返回 E()/dom 元素树；data 为空或 ok=false 时必须渲染对应状态，不能填空壳
    }
});
```

* `rpc.declare()` 直连 rpcd 的 `call`，不经过任何 Lua dispatcher；
* `form.Map` / `form.GridSection` 足以承担线路与规则编辑，不需要 `cbi-*` 的 Lua 后端；
* CSS 注入用 `<link>` + `L.resource('smartmwan/smartmwan.css')`，不用内联 `<style>` 散落各处；
* 轮询必须成对：`poll.add(...)` 在视图加载时注册，`poll.remove(...)` 在离开/销毁时撤销
  （`docs/SECURITY.md` §11 的落点）。

## 4. rpcd 的 ucode 插件

* 放置于 `/usr/share/rpcd/ucode/*.uc`，rpcd 启动时加载，暴露 `name.method` 形式的对象；
* 插件内部可用 `call`/`ubus`/`network` 等 ucode 标准库；本插件的桥只做三件事：
  1. 参数结构校验（不做业务判断）；
  2. 连接守护进程的 Unix socket（`global.rpc_socket`）并转发 JSON；
  3. 把 socket 层的错误映射成 rpcd 错误，避免 UI 看到裸异常；
* ACL JSON 决定哪些用户/组能调哪些方法 —— 授权粒度必须是**方法级**，不是对象通配。

## 5. 对本项目的具体约束（由此得出）

1. 不存在任何 `.lua` 文件的容错空间，包括「临时垫片」；
2. 后端与 Web 之间只有 `JS → rpcd(ucode 桥) → Unix socket → Rust` 这一条链路，
   所以**统一信封与错误码**（`docs/ARCHITECTURE.md` §6）必须在 Rust 侧完成，不能指望前端补语义；
3. 前端展示的所有「状态」都必须来自 RPC 的真实字段或后端给出的 `notes`，
   不得在前端硬编码「正常」之类的占位文案（任务书的诚实性要求）。

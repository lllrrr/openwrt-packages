# luci-app-block-host

基于主机名封锁网络设备的 OpenWrt LuCI 插件。

## 📁 项目结构

```
luci-app-block-host/
├── package/              # OpenWrt ipk 打包配置
│   └── luci-app-block-host/
│       ├── Makefile      # 从 src 复制源码并打包
│       └── root/         # UCI 默认配置
│           ├── etc/
│           └── usr/
├── src/                  # 源代码（唯一源）
│   ├── bind_and_block.sh
│   ├── block_host
│   ├── block_host.init
│   ├── 99-luci-app-block-host
│   ├── luci-app-block-host.json
│   ├── luci-app-block-host.menu.json
│   └── overview.js
├── po/                   # 翻译文件
│   ├── templates/
│   └── zh_Hans/
├── build.sh              # 本地编译脚本（从 src 复制）
├── Dockerfile.build      # Docker 编译配置
├── .github/workflows/    # GitHub Actions CI/CD
└── README.md
```

## 功能特性

- 通过主机名自动识别并封锁设备
- 同时封锁 IP 和 MAC 地址
- 使用 nftables 防火墙规则
- 支持 Web 界面配置
- 定时自动更新规则

## 编译方法

### 方法一：使用 OpenWrt SDK

1. 下载并安装 OpenWrt SDK：
   ```bash
   wget https://downloads.openwrt.org/releases/23.05/targets/x86/64/openwrt-sdk-23.05-x86-64_gcc-12.3.0_musl.Linux-x86_64.tar.xz
   tar xf openwrt-sdk-*.tar.xz
   cd openwrt-sdk-*
   ```

2. 复制插件到 SDK：
   ```bash
   cp -r /path/to/luci-app-block-host/package/luci-app-block-host package/
   ```

3. 配置并编译：
   ```bash
   ./scripts/feeds update -a
   ./scripts/feeds install -a
   make menuconfig  # 选择 LuCI -> Applications -> luci-app-block-host
   make package/luci-app-block-host/compile V=s
   ```

4. 生成的 ipk 文件在：
   ```
   bin/packages/x86_64/base/luci-app-block-host*.ipk
   ```

### 方法二：使用 Docker

```bash
docker build -f Dockerfile.build -t block-host-build .
docker run --rm block-host-build
```

### 方法三：使用 build.sh 脚本

```bash
chmod +x build.sh
./build.sh
```

### 方法四：GitHub Actions

推送代码到 GitHub 仓库，Actions 会自动编译并生成 Release。

## 安装

```bash
# 上传 ipk 到 OpenWrt 路由器
scp luci-app-block-host*.ipk root@192.168.1.1:/tmp/

# SSH 登录并安装
ssh root@192.168.1.1
opkg install /tmp/luci-app-block-host*.ipk
```

## 使用

1. 登录 LuCI Web 界面
2. 进入 **服务** -> **Host Blocker**
3. 启用插件并输入要封锁的主机名（空格分隔）
4. 点击保存并应用

## 配置说明

- **Enable**: 启用/禁用插件
- **Target Hostnames**: 要封锁的主机名列表，例如：`Xiaomi-12X lian-xiang-xiao-xinPad-Pro-12-7`

## 手动测试脚本

```bash
# 手动运行封锁脚本
/usr/bin/bind_and_block.sh

# 查看 nftables 规则
nft list table inet filter_block

# 查看日志
logread | grep bind_and_block
```

## 卸载

```bash
opkg remove luci-app-block-host
```

## 许可证

Apache License 2.0

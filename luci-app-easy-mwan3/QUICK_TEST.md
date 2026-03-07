# 快速测试指南

## 测试方案

由于虚拟机只能通过控制台访问，我们提供两种测试方案：

### 方案 1: 在虚拟机控制台直接测试

#### 步骤 1: 获取虚拟机 IP 地址

在虚拟机控制台输入：
```bash
ip addr show
```

找到类似 `eth0` 或 `br-lan` 的接口，记下 IP 地址（通常是 192.168.x.x）

#### 步骤 2: 测试网络连接

```bash
# 测试外网连接
ping -c 3 8.8.8.8

# 测试 DNS
ping -c 3 google.com
```

#### 步骤 3: 上传 IPK 包到虚拟机

**方法 1: 使用 SCP（如果虚拟机有网络）**

在你的主机上：
```bash
# 在项目目录下
scp luci-app-easy-mwan3_2.1.1_all.ipk root@192.168.x.x:/tmp/
```

**方法 2: 使用 Python HTTP 服务器**

1. 在你的主机上（项目目录）：
```bash
python -m http.server 8000
```

2. 在虚拟机控制台：
```bash
cd /tmp
wget http://192.168.x.x:8000/luci-app-easy-mwan3_2.1.1_all.ipk
```

**方法 3: 手动复制粘贴**

如果以上方法都不行，我们可以创建一个简化的测试脚本。

### 方案 2: 创建简化测试包

让我为你创建一个可以手动复制粘贴的测试方案。

## 快速验证命令

在虚拟机控制台直接运行这些命令：

```bash
# 1. 检查系统版本
cat /etc/openwrt_release

# 2. 检查防火墙版本
uci get firewall.@defaults[0].name 2>/dev/null || echo "unknown"

# 3. 检查 mwan3 是否安装
opkg list-installed | grep mwan3

# 4. 检查 LuCI 是否安装
opkg list-installed | grep luci-base

# 5. 检查必要工具
which ip iptables curl

# 6. 检查网络接口
ip link show

# 7. 检查可用空间
df -h
```

运行完这些命令后，告诉我结果，我会根据你的情况提供下一步指导。

## 手动安装步骤

如果无法上传文件，可以手动创建文件：

```bash
# 创建测试目录
mkdir -p /tmp/test-easy-mwan3
cd /tmp/test-easy-mwan3

# 创建基本的 UCI 配置文件
cat > /etc/config/easy_mwan3 << 'EOUCI'
config global 'global'
    option enabled '0'
    option mode 'balance'
    list members ''

config rule
    option src_ip ''
    option policy 'default'
    option comment ''
EOUCI

# 验证配置文件
uci show easy_mwan3
```

## 下一步

告诉我虚拟机的网络情况，我会提供最适合的测试方案。

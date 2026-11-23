# PVE 测试环境

在 Proxmox VE 上用真实内核和真实固件验证插件（flowtable、真实的 RA/SLAAC、24.10 / 25.12）。
所有虚拟机都在独立的 SDN 区域里，只有 isp 的 WAN 口接家里的局域网（作为普通 DHCP 客户端）。

```
家里局域网(vmbr0) ── lab-isp ── labwan(10.255.0.0/24, 2001:db8:100::/64) ── lab-r24 / lab-r25（同一对 MAC，只开一台）
                                                                              │
                                     lablan(192.168.99.0/24, 2001:db8:100:10::/64)
                                       ├ lab-side   192.168.99.3   网关（单臂转发 + SNAT）
                                       └ lab-hosts  Alpine，netns 里有 client-a(.10, 开 v6 临时地址) / client-b(.11)
```

lab-isp 用 223.5.5.5 / 240e::1 扮演“国内”，8.8.8.8 / 2001:4860::8888 扮演“国外”，回显访问者源地址（`/cgi-bin/ip`），
另有 40MB 文件 `/big`，用于长连接测试。

| 文件 | 用途 |
| --- | --- |
| `99-smartroute-lab` | 注入 ImmortalWrt 镜像的首次启动脚本，按 eth0 的 MAC 配置成 isp / router / side |
| `vms.sh` | 用受限 token（lab@pve）创建、启停、销毁虚拟机 |
| `hosts-setup.sh` | 在 lab-hosts 上创建 client-a / client-b |
| `ssh_config` | `ssh -F ssh_config lab-router` 等跳转配置 |
| `sr.sh deploy\|on\|off\|unselect\|dns\|status` | 部署后台与界面（不覆盖配置），用 UCI 写入测试配置；`dns` 测域名规则 |
| `backend-test.sh` | 故障切换与恢复、经网关探测、压回 v4、拦截、域名记录持久化、netifd 重启、经出口下载（先 `sr.sh on`） |
| `check.sh` | 测试矩阵：SIDE = 经过网关 |
| `fo-test.sh` | 流量卸载开/关 × 长连接、中途改规则 |

实验虚拟机的 root 密码是 `smartroute`，仅用于串口控制台；SSH 只允许密钥登录。

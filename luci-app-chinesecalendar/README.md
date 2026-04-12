luci-app-chinesecalendar
===
Chinese calender for OpenWrt overview page

Compilation notes / 编译
---
**OpenWrt >= 21.02:**

```bash
git clone https://github.com/debugdoctor/luci-app-chinesecalendar.git

mv luci-app-chinesecalendar /path/to/openwrt/package

cd /path/to/openwrt

./scripts/feeds update -a

./scripts/feeds install -a

make menuconfig
# Select luci-app-chinesecalendar as "M" in Luci -> Applications

make package/luci-app-chinesecalendar/compile V=s
```

Installtion notes / 安装
---

```bash
wget https://github.com/debugdoctor/luci-app-chinesecalendar/releases/download/v2.0.1/luci-app-chinesecalendar_2.0.1_all.ipk

opkg install luci-app-chinesecalendar_2.0.1_all.ipk
```

Contributing / 参与贡献
---
If you have any suggestions for improvement or feedback, feel free to open an issue or submit a pull request. Contributions are welcome!

如果你有任何改进建议或反馈，欢迎提交 issue 或 PR，期待你的参与！

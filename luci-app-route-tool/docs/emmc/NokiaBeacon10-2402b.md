# Nokia Beacon 10 (固件 2402b.04.09.A17) eMMC 身份卡

采集: 活设备 `/sys/class/mmc_host/mmc0/mmc0:0001` 寄存器直读（真值源）

## 结论

| 项 | 值 |
|---|---|
| 芯片 | **SkyHigh Memory S40FC002**（原 Renesas 闪存线） |
| 封装 | 9×7.5mm（该系列仅 S40FC002=2GB / S40FC004=4GB 两款） |
| 判型依据 | user area 1,954,545,664B = 2GB 款（4GB 款应约 3.9GB） |
| CID | `01010053343030303401443820d8ba00` |
| MID | `0x01` → **SkyHigh（非三星 0x15）** — route-tool 映射表修正依据 |
| 平台 | Qualcomm IPQ9574 / 双 QCN9000 射频 |

## CID 解码（JESD84-B51，6 字节 PNM 布局，与内核读数一致）

```
01 | 0100 | 53 34 30 30 30 34 | 01 | 44 38 20 d8 | ba | 00
MID  OID   PNM "S40004"        PRV  PSN 序列号    MDT  CRC
```
- PNM = `S40004`（6字节，SkyHigh S40FC 系列短名）
- PRV = 0x01
- PSN = 0x443820d8
- MDT = 0xBA → month=0xB(11月) year=0xA(2013+10=2023) → **2023-11**

## 关键硬件参数

```
User Area   : 1,954,545,664 B ≈ 1.95GB (3817472 扇区)
增强区      : ~977MB SLC (enhanced_area_size=1908736 扇区)
RPMB        : 4MB (raw_rpmb_size_mult=0x20×128KB, 鉴权读取实证 I/O error)
boot0/boot1 : 4MB×2 全零（启动链走 User Area GPT，双端确认）
健康度      : life_time 0x01/0x01（A/B 均 0-10%），pre_eol_info=0x01 Normal
EXT_CSD rev : 8 (JESD84-B51), ffu_capable=1
erase_size  : 512KB (preferred 4MB)
```

## 原始数据

`data/` 内含: `cid` `csd` `registers.txt`（sysfs 全量快照）`boot0.bin.gz` `boot1.bin.gz`（全零 gzip 实证）`rpmb_dev.txt` `rpmb_read_err.txt`

关联夹具: `tests/emmc_cid_fixtures.csv` → 行 `NokiaBeacon10-2402b`（`sh tests/check-emmc-cid.sh` 回归通过）

---
name: centos7-iso-build
description: 从官方 CentOS-7 Minimal 原盘构建定制全自动装机 ISO(可选双内核 / GPT / 双引导 / 网卡改名 / 多盘选盘)的完整经验与踩坑清单。改 ks、改选盘/选网卡、重建镜像、真机验证时使用。
---

# CentOS 7.9 定制装机 ISO —— 构建技能与踩坑全记录

> 适用对象:本仓库(`build.sh` / `overlay/isolinux/ks.cfg` / `overlay/isolinux/isolinux.cfg` / `overlay/EFI/BOOT/grub.cfg`)
> 本文档原为一条内部流水线的实战记录,已脱敏:**所有绝对路径都改成仓库内相对路径**,
> 内网地址/主机名/口令已去掉,版本号与 MD5 属于历史构建(你的构建结果必然不同)。
> 文中 `re.sh` / `push.sh` 是当年"改版本号+推送"的脚本,本仓库里对应 `./build.sh`(推送不在范围内)。

---

## 0. 三句话总纲

1. **改 ks 是改"运行时逻辑",不是改文本** —— 静态语法检查过了不代表对,必须真装机。
2. **凡是"选硬件"(选盘/选网卡)的逻辑,必须在"多盘、混合 SSD/HDD、带旧系统、带 U 盘"的机器上验证**;单盘干净 VM 只能验证"能装",验证不了"选对"。
3. **破坏性操作必须显式限定范围**(`clearpart --drives=`、`part --ondisk=`、`parted /dev/$DISK`),永远不要依赖"默认只影响一块盘"的假设。

---

## 1. 目录与流水线

```
centos7-iso-build/
├── build.sh                       # 入口:解包原盘 → 覆盖 overlay → 重建 repodata → 打包 → 自检
├── overlay/                       # 要覆盖进原盘的定制文件
│   ├── isolinux/ks.cfg            # 唯一 kickstart
│   ├── isolinux/isolinux.cfg      # BIOS 菜单
│   ├── EFI/BOOT/grub.cfg          # UEFI 菜单(外层;build.sh 同步进 efiboot.img 内层)
│   └── files/                     # 自定义载荷(check、edge-firstboot、/root 脚本…)
├── docs/                          # 本文件 + BUGS.md
└── .build/                        # 构建时生成(解包树 isolinux/ EFI/ images/ Packages/ repodata/)
    └── isoroot/
        ├── isolinux/isolinux.bin  # ★必须用原盘的(mkisofs 校验依赖它)
        ├── images/efiboot.img     # ★内层 grub.cfg 必须同步,否则 UEFI 装机会走原厂菜单
        ├── Packages/              # rpm 池(原盘 447 个,注入内核后 448 个)
        └── repodata/              # ★location 必须带 Packages/ 前缀
```

**重建一条命令**:`./build.sh CentOS-7-x86_64-Minimal-2009.iso out.iso`
**想改版本/卷标**:`--label XXX --menu-title 'XXX'`(build.sh 会把卷标同时写进三处)
**铁律**:任何真机测试在跑时,不要重新构建同一路输出文件(会换掉 ISO,测试结果作废)。

---

## 2. ISO 内容检查(不挂载)

```bash
isoinfo -d -i X.iso | head -20                        # 卷标/引导
isoinfo -R -f -i X.iso | grep -E 'isolinux|EFI/BOOT|repodata' | head
isoinfo -R -i X.iso -x /isolinux/ks.cfg > /tmp/ks    # 取单个文件
# 内层 efiboot.img 的 grub.cfg(易漏!)
isoinfo -R -i X.iso -x /images/efiboot.img > /tmp/efi.img
mkdir /tmp/m && mount -o loop,ro /tmp/efi.img /tmp/m && cat /tmp/m/EFI/BOOT/grub.cfg
```
**永不 `mount` 整个 ISO**;只用 `isoinfo -R -x`。

---

## 3. kickstart 结构与关键设计

### 3.1 `%pre` 的执行顺序(血泪)

```
① 候选盘枚举(排除可移动/USB/Ventoy/loop/sr/zram/nbd/dm/md)   ← ★ 必须放在所有分支之前
② if grep -q static /proc/cmdline  → 手动:选网络类型/网卡/磁盘,写 /run/.iface、/run/.disk
③ if grep -q auto   /proc/cmdline  → 自动:按策略选盘 → 写 /tmp/other.ks
④ KS-SELFCHECK:/tmp/other.ks 为空 ⇒ 清屏横幅 + 列块设备 + exit 1
```
**踩过的坑**:把 ① 写进 ② 的分支内 ⇒ Auto 分支拿到空列表 ⇒ 打 `AUTO INSTALL ABORTED` + `exit 1`(而 **`%pre` 的 exit 并不阻止 anaconda 继续**)⇒ `/tmp/other.ks` **0 字节** ⇒ 屏幕停在 `No disks selected`,安装器静默等人输入。

### 3.2 跨段传参

`%pre` 与 `%post` 是**不同进程**,靠 **`/run/`** 传递(它会被 bind 进 chroot):
```
%pre : echo "$INTERFACE" > /run/.iface ; echo "$DISK" > /run/.disk
%post: [ -s /run/.iface ] && 用 /run/.iface 优先
```

### 3.3 选盘(1.0.182 策略)

```sh
# 候选盘:整盘 - 可移动 - USB总线 - Ventoy标签 - loop/sr/zram/nbd/dm/md/fd
[ "$(cat /sys/block/$d/removable)" = "1" ] && continue
readlink -f /sys/block/$d | grep -q '/usb' && continue
lsblk -lno name,label /dev/$d | awk 'tolower($2)~/vtoy|ventoy/' && continue
# 列表:★ 名字+容量必须成对,否则编号选盘永远选不中
alldisk=$(echo $alldisk | xargs -n2 | cat -n)      # 1 sda 6.0T / 2 sdm 800G
# Auto:排掉 <110GiB 后取最小
_bytes=$(( $(cat /sys/block/$n/size) * 512 ))
# 写盘:显式限定
clearpart --all --initlabel --drives=$DISK
part /boot --fstype xfs --ondisk=$DISK --size 1024
```

### 3.4 网卡 → eth0 改名(优先级链)

```
0) /run/.iface(手动 Select 选的那张,最高优先)
1) 第一个 operstate=up 的物理网卡
2) 都没有 up ⇒ 第一个"驱动在白名单里"的网卡
   (ixgbe/ixgbevf/i40e/i40evf/ice/iavf/igb/mlx4_en/mlx5_core/bnxt_en/be2net/cxgb4/qede/sfc/nfp/txgbe/ngbe)
   ★ 没插光纤时 /sys/class/net/*/speed 是 -1,只靠 speed>=10000 会失效
3) 再退一步:第一个 speed >= 10000 的网卡
4) 都不满足 ⇒ 不改名,只打 WARNING(不猜)
```
改名三件套(**缺一就会出现"设备叫 eth0 但连接名叫 ens192"或 `network.service` 失败**):
```sh
/etc/udev/rules.d/70-persistent-net.rules     # 按 MAC 绑定 NAME="eth0"(C7 上真正生效)
/etc/systemd/network/10-eth0.link             # 双保险 [Match] MACAddress → [Link] Name=eth0
ifcfg-eth0:DEVICE=eth0 / NAME="eth0" / HWADDR=<MAC> / 删 UUID / 加 PEERDNS=no
旧 ifcfg 备份 ⇒ /var/backups/(★不能留在 network-scripts,也不能放 /root)
```

### 3.5 `%post` 清单(13 段,每段 `--log=`)

`nochroot / rc-local / console(linux-tty) / default-kernel / smartmontools / raidtools / grub-cmdline / repos / nezha / chrony / eth0 / baseline(sshd+firstboot) / …`

要点:
- **`crashkernel=128M`**(5.4 内核不认 `auto`,kdump 会 failed);
- **`GRUB_TIMEOUT=1` 必须在 `%post` 里自己 `grub2-mkconfig` 重建 + `sed` 兜底**,否则被 anaconda 覆盖回 5;
  `sed` 正则要容忍缩进:`s/^[[:space:]]*set timeout=.*/set timeout=1/`
- **`reboot --eject`** 必须写(虚拟光驱挂 **`ide1:0`** 时在 ESXi 上能正常弹出;挂 `sata0:1` 时可能弹不掉 ⇒ 循环重装);
- `smartmontools` 装完 **`systemctl disable --now smartd`**(不告警);装包用 **`rpm -Uvh --replacepkgs`**(`-ivh` 遇"已安装"会中止整个事务);
- 装机报告 `/var/log/tcec-install-report.txt` + firstboot 自检(`tcec-firstboot.service`,跑完自我 disable,**不要自动重启**)。

---

## 4. 仓库(repodata)最容易错的两件事

```bash
# ✅ 正确:递归扫描 ISO 根,location 才带 Packages/ 前缀
createrepo_c -g /tmp/comps.xml -o /tmp/rdnew "$TREE"     # TREE = 解包出来的 ISO 根
rm -rf work/isoroot/repodata && cp -a /tmp/rdnew/repodata work/isoroot/repodata
```
- ❌ 若对 `Packages/` 目录做 `createrepo_c`,得到的 `href` 是**裸文件名** ⇒ anaconda 报 `Errno 256` / `incorrect checksum`;
- ❌ `/repodata` 绝对不能藏在 `Packages/` 里面 ⇒ anaconda 报 `Error setting up software source`;
- **验证必须做真实事务**:
```bash
yum -y --installroot=/tmp/rt/root --releasever=7 --setopt=reposdir=/tmp/rt/repos \
          --setopt=cachedir=/tmp/rt/cache --downloadonly install @core
# rc=0 且 Install N Packages / Complete! 才算过
```

---

## 5. 双引导(BIOS + UEFI)

| 位置 | 要点 |
|---|---|
| `isolinux/isolinux.cfg` | `timeout 300`(≈15s) + `menu default` 放在 **Auto** |
| `EFI/BOOT/grub.cfg`(外层) | `set default="1"`、`set timeout=…menu` |
| **`images/efiboot.img` 内层** | **必须与外层同步**(卷标、`inst.ks=`、`set default`)—— **UEFI 装机真正读的是它** |
| kickstart | `[ -d /sys/firmware/efi ]` ⇒ `part /boot/efi --fstype=efi --ondisk=$DISK --size=200`,否则 `part biosboot --fstype=biosboot --size=1` |
| `%post` | 两套 grub.cfg 都要处理:`/boot/grub2/grub.cfg` + `/boot/efi/EFI/centos/grub.cfg` |
| 验证 | UEFI:`[ -d /sys/firmware/efi ]`、`parted` 见 ESP 210M、`efibootmgr -v` 指向 `\EFI\centos\shimx64.efi`、`/boot/efi/.../grub.cfg` 里 `set timeout=1` |

---

## 6. 真实环境(ESXi / KVM)踩坑表

| 现象 | 原因 | 处理 |
|---|---|---|
| UEFI 虚机 30 秒内 **`MONITOR PANIC: IOAPIC`** | **vmx 里 `guestOS` 写成 `centos7_64`(下划线)是非法的** ⇒ 判成 otherGuest ⇒ 加载 **32-bit EFI ROM** | 用 **`centos7-64`**(连字符);vSphere UI 选 "CentOS 7 (64-bit)" 最稳 |
| 装完又从光盘进安装界面 | `reboot --eject` 在 ESXi/iDRAC 上不彻底(尤其光驱挂 `sata` 时) | 装完**手动 Unmap/断开虚拟介质**,或 `ide1:0.present=FALSE` + `bootOrder=hdd` |
| `[datastore (N)]` 形式的 CD 路径打不开 | hostd 不认方括号别名 | 用**绝对路径** `/vmfs/volumes/<ds>/iso/x.iso` |
| `md5sum` 报 `Device or resource busy` | 有虚机正挂着该 ISO | 关机/断开 CD 后再算,或在 guest 内算 |
| ESXi 原生 VNC 连不上 | ESXi 8 禁 `RemoteDisplay.vnc`,只给 **webmks ticket** | 起本地桥(`wss://…/ticket/<tk>` → `127.0.0.1:59xx`)再用 `vncdotool` |
| **`serial0` 串口后端不工作** | ESXi 8.0.3:`file` 建了 0 字节、`network` 从不连接(guest UART 正常) | 别指望串口取证,用 webmks 截图/日志代替 |
| 装到第二块盘后 `Operating System not found` | legacy BIOS 只从**第一块盘**找 MBR | PhoenixBIOS(F2)→ Boot → Hard Drive → 把该盘 `+` 提前 → F10;UEFI 无此问题 |
| `virt-install`/ESXi 建 UEFI 机必须 64 位 ROM | 同上 `guestOS` | 见第一行 |

---

## 7. 验证方法论(最重要的一节)

### 7.1 验收矩阵(每次改 ks 都要跑)

| 场景 | 必测 | 说明 |
|---|---|---|
| **Auto + BIOS** | ✅ | 零输入、目标盘正确、分区/内核/网卡/服务 |
| **Auto + UEFI** | ✅ | ESP/efibootmgr/timeout |
| **手动 Select** | ✅ | 编号选网卡/选盘、`/run/.iface` 生效、装到第二块盘 |
| **多盘场景** | ✅★ | 至少 VM 配 **2 盘**(SSD+HDD 混合更好),否则选盘逻辑等于没测 |
| **重装场景** | ✅ | 在**已有系统**的盘上装(旧 swap/LVM 会 EBUSY) |
| **U 盘/Ventoy 场景** | 脚本仿真 | ESXi 无法模拟 `removable`,可用伪造 sysfs 或真机 |

### 7.2 取证

```bash
# 安装器的 %pre 日志在【目标机】的这里(不在 guest 的 journalctl!)
grep -a '\[pre\]' /var/log/anaconda/program.log | tail -20
grep -a -o 'LABEL=[A-Za-z0-9_.-]*' /var/log/anaconda/*.log | sort -u
grep -aE 'BIOSBoot.create|PartitionDevice.create|DiskLabel.commitToDisk|XFS.doFormat' \
     /var/log/anaconda/storage.log | head -20      # ★ 证明"只动了目标盘"
```

### 7.3 交付前三查

```bash
# ① 镜像内实际内容(不是构建树)
isoinfo -R -i X.iso -x /isolinux/ks.cfg | grep -nE 'clearpart|ondisk|MIN_BYTES|xargs -n2'
# ② 仓库真实事务
yum … --downloadonly install @core        # rc=0
# ③ 双推 + 远端校验
sha256sum out.iso                         # 与交付记录比对(推送不在本仓库范围)
```

---

## 8. 已踩并修复的问题清单(按时间)

| # | 问题 | 根因 | 修法 |
|---|---|---|---|
| 1 | 装完不弹介质,循环重装 | 缺 `reboot --eject` | 加参数;虚拟光驱用 `ide1:0` |
| 2 | UEFI 装机走原厂菜单 | `efiboot.img` 内层没同步 | 每次改外层同步内层 |
| 3 | `repodata` href 缺 `Packages/` | 对 Packages 目录跑 createrepo | 递归扫 ISO 根 |
| 4 | `smartmontools` 装不上 | `-ivh` 遇已安装包中止事务 | `rpm -Uvh --replacepkgs` |
| 5 | kdump 每次 failed | 5.4 内核不认 `crashkernel=auto` | `crashkernel=128M` |
| 6 | `GRUB_TIMEOUT` 被改回 5s | anaconda 重生成 | `%post` 里 `grub2-mkconfig` + sed(容忍缩进) |
| 7 | **重装到已有系统的盘 ⇒ parted EBUSY** | 旧 swap/LVM/dm/md 占用 | `%pre` 里 `swapoff -a; vgchange -an; dmsetup remove_all; mdadm --stop --scan; multipath -F; umount` |
| 8 | **Auto 100% 装不上(`No disks selected`)** | 候选盘枚举写进 static 分支内 ⇒ Auto 拿到空列表 | 枚举提到分支前 + `KS-SELFCHECK` |
| 9 | **编号选盘永远 invalid(2 块盘显示 4 条)** | `tr ' ' '\n' \| cat -n` 把"盘名 容量"拆行 | `xargs -n2 \| cat -n` |
| 10 | **Auto 装到大容量数据盘(6T)** | 策略是"第一块" | 改"≥110GiB 里最小盘" + 大字目标盘提示 |
| 11 | `network.service` failed | 旧 ifcfg 备份留在 `network-scripts/` | 备份移到 `/var/backups/` |
| 12 | `/root` 不干净 | 备份文件放 `/root` | 同样移到 `/var/backups/` |

---

## 9. 写代码时的自身纪律(我反复犯的)

1. **Python 脚本里不要出现中文引号** —— 会直接 `SyntaxError`,而且**补丁不会生效**(多次踩);
2. **幂等判断不要用宽泛 grep**(`grep 'NAME="eth0"'` 会命中 udev 规则那行 ⇒ 误判"已打过补丁");
3. **每段 `%pre/%post` 单独 `bash -n`**,并且**改完必须从 ISO 里再读出来核对**(不是看构建树);
4. **列表/编号类输出**:成对、带单位、带类型(SSD/HDD);
5. **破坏性命令**:显式带目标参数;
6. **改完必须真机装一次**,并用 `program.log`/`storage.log` 自证。

---

## 10. 现场注意(交付给施工方)

- **系统盘 ≥ 110 GB**(`/data` 固定 100G);
- **装完务必卸载虚拟介质**(iDRAC Unmap / vSphere 断开 CD);
- **装到非第一块盘时**,BIOS/RAID 里把该盘设为第一启动盘(UEFI 无此限制);
- Auto 会**在屏幕上打印目标盘 5 秒**,发现不对立刻断电;
- 需要**手动指定**时用菜单第 2 项 `Select Install CDN Server`,按**编号**选网卡/磁盘即可。

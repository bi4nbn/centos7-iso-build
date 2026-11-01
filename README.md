# centos7-iso-build

**一张官方 `CentOS-7-x86_64-Minimal-2009.iso` 原盘 + 一条命令 → 一张开箱即用的定制自动安装盘。**

```bash
./build.sh CentOS-7-x86_64-Minimal-2009.iso centos7-custom.iso
```

生成的是**BIOS + UEFI 双引导**的 CentOS 7.9 全自动装机 ISO:零输入选盘、GPT 分区、网卡改名 `eth0`、
GRUB 1 秒超时、装完自动弹介质、首启硬件体检报告。原盘不用改、不用挂载、不用 root 也能跑
(只有改 `efiboot.img` 内层菜单那一步需要 `mtools` 或 root,见下)。

> 构建与踩坑的完整经验见 [`docs/BUILD-SKILL.md`](docs/BUILD-SKILL.md),已知缺陷与观察见 [`docs/BUGS.md`](docs/BUGS.md)。
> **改 kickstart、改选盘/选网卡逻辑之前先读 BUILD-SKILL 第 7 节(验收矩阵)和第 9 节(纪律)。**

---

## 1. 依赖

只要 4 个命令,不需要 root(除非改 `efiboot.img` 时本机没有 `mtools`):

```bash
# RHEL / CentOS 7
yum install -y genisoimage createrepo_c rsync mtools

# Debian / Ubuntu
apt install -y genisoimage createrepo-c rsync mtools

# 可选:xorriso(解包更快,内部改用 `xorriso -osirrox on -extract /`)
```

| 命令 | 来自 | 用途 |
|---|---|---|
| `isoinfo` / `genisoimage` | genisoimage(1.1.11) | 解包原盘 / 重打 El Torito 引导 |
| `createrepo_c` | createrepo_c(0.20.x) | 重建 `repodata`(必须扫 ISO 根) |
| `rsync` | rsync | 覆盖 `overlay/` |
| `mcopy`(mtools) | mtools | 免 root 写 `images/efiboot.img` 内层 `grub.cfg` |

实测环境:AlmaLinux 9.8 / genisoimage 1.1.11 / createrepo_c 0.20.1 / xorriso 1.5.4,
构建一次约 **30 秒**,峰值额外磁盘 ≈ 2.2 GB。

## 2. 三步

```bash
# 1) 拿仓库
git clone https://github.com/<owner>/centos7-iso-build && cd centos7-iso-build

# 2) 把官方原盘放到当前目录(约 973 MiB)
#    https://mirrors.huaweicloud.com/centos-vault/7.9.2009/isos/x86_64/CentOS-7-x86_64-Minimal-2009.iso
#    校验:SHA256 见 CentOS 官方 sha256sum.txt(2009 版)

# 3) 一条命令
./build.sh CentOS-7-x86_64-Minimal-2009.iso centos7-custom.iso
```

可选参数:

```bash
# 自带内核 rpm 注入(默认只装官方 3.10)
./build.sh CentOS-7-x86_64-Minimal-2009.iso out.iso --kernel-rpm ./kernel-5.4.x.rpm

# 换 root 口令 / 换卷标 / 换菜单标题
./build.sh CentOS-7-x86_64-Minimal-2009.iso out.iso --rootpw 'S3cret!' --label MYEDGE --menu-title "My Edge ISO"

# 不要 eth0 改名(保留 CentOS 默认的 ens*/eth* 命名)
./build.sh CentOS-7-x86_64-Minimal-2009.iso out.iso --no-eth0

# 注入额外载荷(linux-tty TUI、阵列卡 rpm 等,见 optional/README.md)
./build.sh CentOS-7-x86_64-Minimal-2009.iso out.iso --payload-dir optional/linux-tty
```

完整参数:`./build.sh --help`。

### 输出样例

```
================================ 构建完成 ================================
  输出 ISO : /tmp/out/CentOS-7-custom.iso
  体积     : 1081145344 字节 (1031 MiB)
  卷标     : CENTOS7_CUSTOM
  MD5      : 299e2586ebc2f091597cf4bcbfa64de7
  SHA256   : a2b192f14add640679c33d5ad614803c543511929811c747646d8145431742bd
  内核     : 仅官方 3.10
  写入 U 盘: dd if='CentOS-7-custom.iso' of=/dev/sdX bs=4M status=progress oflag=sync
=========================================================================
```

> 每次构建的 MD5 都不同(ISO 里写了构建时间戳),**以你本机的输出为准**。

## 3. 它做了什么

| # | 能力 | 细节 |
|---|---|---|
| 1 | **两种安装模式** | 菜单第 1 项 **Auto**(零输入) / 第 2 项 **Select**(手动选网络类型 → 选网卡 → 选磁盘,编号或名字都能输) |
| 2 | **自动选盘** | 排除 可移动 / USB 总线 / Ventoy / loop / sr / zram 后,取**「容量 ≥110 GiB 里最小的那块」**;装前**大字打印目标盘 + 全部候选盘**,5 秒后自动继续 |
| 3 | **GPT 分区** | `/boot` 1G · **`/data` 100G** · `/` 剩余;BIOS 加 `biosboot`,UEFI 加 200M ESP。**系统盘需 ≥110 GB** |
| 4 | **BIOS + UEFI 双引导** | isolinux(BIOS)+ `images/efiboot.img`(UEFI);`build.sh` 会把新菜单**同步写进 efiboot.img 内部**(UEFI 真正读的是那份) |
| 5 | **双内核(可选)** | 默认**只装官方 3.10**;传 `--kernel-rpm` 后自动变成"注入内核 + 官方 3.10"并存,默认启动项取版本更高的那个 |
| 6 | **网卡改名 eth0** | 优先级:手动所选 → 第一个 UP → 第一个 10G 驱动白名单网卡 → 第一个 speed≥10G;三件套 `udev` 规则 + `systemd .link` + `ifcfg`(`DEVICE/NAME/HWADDR`、删 `UUID`、`PEERDNS=no`);旧配置备份到 `/var/backups/` |
| 7 | **GRUB 1 秒** | `GRUB_TIMEOUT=1` 写进 `/etc/default/grub`,并在 `%post` 里 `grub2-mkconfig` + `sed` 兜底(否则被 anaconda 改回 5 秒) |
| 8 | **`crashkernel=128M`** | 5.4 内核不认 `auto`,写死 128M 才能让 kdump 不 failed |
| 9 | **装完弹介质** | `reboot --eject`(虚拟光驱建议挂 `ide1:0`) |
| 10 | **首启体检** | `/usr/local/bin/check`(整机/CPU/内存槽位/硬盘 SN/网卡)→ `/var/log/edge-hardware.txt`;首启生成 `/var/log/edge-install-report.txt` 后自我 `disable`(`edge-firstboot.service`,**不自动重启**) |
| 11 | **软件源** | 华为云 CentOS-Vault 7.9.2009(base/updates/extras)+ EPEL 7;`/etc/yum.conf` 里 `exclude=` 锁死内核系包,不再被升级 |
| 12 | **sshd 调优** | `UseDNS no` + `GSSAPIAuthentication no` |
| 13 | **重装安全** | `%pre` 先 `swapoff -a` / `vgchange -an` / `dmsetup remove_all` / `mdadm --stop --scan` / `multipath -F`,避免旧系统占用导致 `parted` EBUSY |
| 14 | **可选载荷** | `--payload-dir` 可注入 `linux-tty`(TUI 控制台菜单)、`perccli64`/`storcli64`/`ssacli`(阵列卡)、`smartmontools` 等,**仓库本身不含这些二进制** |

### 内核策略(重要)

* **默认**:只用官方 `kernel-3.10.0-1160.el7`,什么都不用准备;
* **可选**:`--kernel-rpm ./kernel-5.4.x.rpm` 把任意内核 rpm 放进 `Packages/` 并重建 `repodata`,
  `build.sh` 会自动填 `kernel-3.x.*` 到 `%packages`,形成双内核并存;
* **仓库不分发任何内核 rpm**(尤其不含内部 TL2 内核),也不含任何 ISO。

## 4. 要求与注意

| 项 | 说明 |
|---|---|
| **系统盘 ≥ 110 GB** | `/data` 固定 100G,小于 110G 会报 `Unable to allocate requested partition scheme` |
| **装完手动卸载虚拟介质** | `reboot --eject` 在部分 iDRAC/ESXi 上弹不彻底,需手动 Unmap / 断开 CD;否则会又从光盘进安装器 |
| **装到非第一块盘要改启动顺序** | legacy BIOS 只从第一块盘找 MBR ⇒ 进 BIOS → Boot → Hard Drive 把该盘提前;UEFI 无此问题 |
| **Auto 会打印目标盘 5 秒** | 屏幕上大字显示 `ONLY /dev/sdX WILL BE WIPED`;**发现不对请立刻断电** |
| **UEFI 虚机 `guestOS` 要写 `centos7-64`** | 写成 `centos7_64`(下划线)会加载 32-bit EFI ROM ⇒ `MONITOR PANIC: IOAPIC` |
| **换卷标后不要手改菜单** | 卷标由 `--label` 统一写在 isolinux/grub/**efiboot.img 内层**三处,`build.sh` 会自动同步;手改会漏一处导致 UEFI 找不到光盘 |

## 5. 验证

**构建期**(`build.sh` 自己会做,失败会红字退出):卷标回读、`ks.cfg` 内 `rootpw` 为 sha512 哈希、
`isolinux.cfg` 里 `LABEL=` 与卷标一致、`%packages` 里的可选包在 `Packages/` 中真实存在、
`repodata` 扫描的是 ISO 根(`location href` 带 `Packages/` 前缀)。

**成品自检**:

```bash
isoinfo -d -i centos7-custom.iso | grep 'Volume id'          # 应等于 --label
xorriso -indev centos7-custom.iso -report_el_torito plain | grep -E 'boot img|img path'
#   → BIOS /isolinux/isolinux.bin  +  UEFI /images/efiboot.img
isoinfo -R -i centos7-custom.iso -x /isolinux/ks.cfg | head -40
```

**装完逐条核对**:

```bash
# 内核
rpm -qa | grep -i '^kernel' | sort           # 默认只有 kernel-3.10.0-1160*;注入了就有两个
uname -r
grubby --default-kernel                      # 双内核时应指向高版本

# 分区(gpt + bios_grub 或 ESP 200M + /boot 1G + /data 100G + /)
parted -s /dev/sda print | head -8
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT

# 引导
grep -m1 'set timeout' /boot/grub2/grub.cfg                  # set timeout=1
grep -m1 'set timeout' /boot/efi/EFI/centos/grub.cfg 2>/dev/null
efibootmgr -v 2>/dev/null | grep -E 'BootCurrent|CentOS'     # UEFI 机

# 网卡
ip -br link | grep -v LOOPBACK                # 期望 eth0
nmcli -t -f NAME,DEVICE c show                # 期望 eth0:eth0
grep -E '^(DEVICE|NAME|HWADDR|PEERDNS)=' /etc/sysconfig/network-scripts/ifcfg-eth0
cat /var/log/ks-post-eth0.log | head -3       # >>> manual selection wins / selected NIC …

# 服务与体检
systemctl --failed --no-legend                # 期望空
systemctl is-enabled edge-firstboot.service   # 期望 disabled(首启跑完自我停用)
check && head -12 /var/log/edge-hardware.txt
head -14 /var/log/edge-install-report.txt

# 软件源
yum repolist | head; grep -E '^(exclude|baseurl)' /etc/yum.conf /etc/yum.repos.d/*.repo | head
```

**重装场景**额外确认:`/var/log/anaconda/storage.log` 里只出现目标盘的 `create/wipe/format`,
不应出现别的盘:

```bash
grep -aE 'BIOSBoot.create|PartitionDevice.create|DiskLabel.commitToDisk|XFS.doFormat' \
     /var/log/anaconda/storage.log | head -20
```

## 6. FAQ

**Q:装完又进安装界面?**
A:虚拟介质没断开。iDRAC → Unmap;vSphere → 编辑设置里断开 CD。光驱挂 `ide1:0` 时 `reboot --eject` 基本能自动弹。

**Q:Auto 装到了数据盘?**
A:选盘策略是"≥110 GiB 里最小的那块",并且装前会**大字打印目标盘**。若仍不对,把
`/var/log/anaconda/program.log` 里 `[pre]` 那几行发出来。想手工指定就用菜单第 2 项 Select 按编号选。

**Q:装完 `network.service` failed?**
A:检查 `/etc/sysconfig/network-scripts/` 里有没有残留 `ifcfg-*.bak-*`。本盘把备份统一放到 `/var/backups/`,
因为该目录下任何 `ifcfg-*` 都会被 `network.service` 当成网卡去启动。

**Q:`nmcli` 里连接名是 `ens192` 而不是 `eth0`?**
A:`ifcfg` 的 `NAME=` 没同步。临时修:

```bash
sed -i 's/^NAME=.*/NAME="eth0"/' /etc/sysconfig/network-scripts/ifcfg-eth0
sed -i '/^UUID=/d'              /etc/sysconfig/network-scripts/ifcfg-eth0
nmcli connection reload && systemctl restart NetworkManager
```

**Q:kdump 开机 failed?**
A:`crashkernel` 必须是 `128M`(5.4 内核不认 `auto`)。检查 `/etc/default/grub`、
`/boot/grub2/grub.cfg`(UEFI 机还有 `/boot/efi/EFI/centos/grub.cfg`)。

**Q:构建时报 `无法修改 images/efiboot.img`?**
A:装 `mtools`(`mcopy` 免 root 写入),或者用 root 跑(`build.sh` 会退回 `mount -o loop,rw`)。

**Q:注入内核后安装失败(依赖缺)?**
A:注入的内核 rpm 的依赖也必须能从这张盘里满足。`linux-firmware`/`dracut`/`grubby` 官方 Minimal 盘里都有;
若你的内核依赖别的包,先把那个 rpm 也丢进 `Packages/`(例如 `--payload-dir`)再构建。

**Q:能不能换成完整版 DVD 原盘?**
A:可以,`build.sh` 只要求树里有 `isolinux/isolinux.bin`、`images/efiboot.img`、`Packages/`、`repodata/`(含 comps)。

## 7. 仓库结构

```
centos7-iso-build/
├── build.sh                     # ★ 一键构建(解包 → 覆盖 overlay → 重建 repodata → genisoimage → 自检)
├── overlay/                     # 要覆盖进原盘的定制文件
│   ├── isolinux/ks.cfg          #   ★ kickstart(纯文本,可直接改)
│   ├── isolinux/isolinux.cfg    #   BIOS 菜单(含 __LABEL__ 占位符)
│   ├── EFI/BOOT/grub.cfg        #   UEFI 菜单(会被同步写进 efiboot.img)
│   └── files/                   #   装进目标机的载荷:check、edge-firstboot、/root 脚本、EPEL key…
├── optional/                    # 不随仓库分发的二进制(见 optional/README.md)
│   ├── linux-tty/               #   TUI 控制台菜单(缺 linux-tty 二进制,其余 unit 已给)
│   └── vendor-rpm/              #   阵列卡 / smartmontools 等厂商 rpm
├── docs/
│   ├── BUILD-SKILL.md           # 构建技能与踩坑全记录(必读)
│   └── BUGS.md                  # 缺陷与观察记录
├── LICENSE                      # MIT
└── README.md
```

构建中间产物在 `.build/`(已在 `.gitignore` 里),`--keep-work` 可保留解包树排查。

## 8. 许可

MIT,见 [LICENSE](LICENSE)。`overlay/` 里的 centos/RHEL 相关配置遵循其上游许可;
`optional/` 里的第三方二进制(若有)按其各自厂商许可分发,本仓库不包含它们。

> CentOS 是 Red Hat 的商标,本项目仅对其安装介质做自动化封装,与 Red Hat / CentOS 项目无关联。

# 已知问题与观察记录(BUGS)

> 适用镜像:本仓库 `build.sh` 的产品(基础 = 官方 CentOS-7-x86_64-Minimal-2009)
> 记录时间:2026-10-23 · 所有条目均来自真实装机/真机验证,不是推测

---

## BUG-1(Auto 装完在 KVM 虚机里停在 `shut off`,不自动重启)

| 项 | 内容 |
|---|---|
| 现象 | ks 里是 `reboot --eject`;在 **libvirt/QEMU 虚机**里装完后,`virsh domstate` 变为 **`shut off`**(不是关闭再重启),需手工 `virsh start` 才能进新系统 |
| 复现 | 测试机(KVM/libvirt)上 `test160-bios`、`test161-bios` 均如此 |
| 影响 | **仅影响"装完是否自动进系统"**;磁盘已装好、手工启动后一切正常,安装本身无失败 |
| 判断 | 与 `--eject` **无关**(1.0.160 用无参 `reboot` 时同样停在 shut off)⇒ 更像 **anaconda 在 QEMU 下的重启方式(ACPI/`reboot -f`)问题** |
| 物理机 | 现场物理机/ESXi 上观察到的都是**正常重启**(此前多台装机均如此) |
| 待验证 | ①用 `reboot`(不带 --eject)在虚机里再测一次;②看 anaconda 日志 `reboot` 前后的 `systemd` 关机原因;③必要时改用 `%post` 里显式 `systemctl reboot`(但会与 anaconda 的收尾冲突,风险高) |
| 状态 | **未修**,待定位 |

---

## BUG-2(libvirt `--cdrom` 的虚拟光驱在装完自动脱离,导致 eject 无法验证)

| 项 | 内容 |
|---|---|
| 现象 | `virt-install --cdrom` 建的虚机,装完后 `virsh domblklist` 里 `hda` 为 **空**(介质已自动卸载) |
| 影响 | 虚机里**无法用 eject 行为验证** `reboot --eject` 是否生效;物理机/iDRAC 上才是真实场景 |
| 结论 | 非产品缺陷,属 libvirt 行为;`reboot --eject` 的效果只能在**物理机 + iDRAC 虚拟介质**上验证 |
| 状态 | 记录,不修 |

---

## BUG-3(iDRAC 虚拟介质对 `eject` 响应可能不彻底)

| 项 | 内容 |
|---|---|
| 现象 | 个别 iDRAC 固件收到 eject 后,虚拟介质仍"挂载但无盘" |
| 影响 | 不会自动进安装界面(盘里已无引导内容),但需人工 **Unmap** 才彻底干净 |
| 建议 | 现场装完顺手在 iDRAC 里 Unmap;或在 iDRAC 上设置"一次性引导到硬盘" |
| 状态 | 现场操作约束,非镜像缺陷 |

---

## OBS-1(`%post` 日志是 9 个而不是 11 个)

`%post --nochroot` 的日志写在 **`/root/ks-post-nochroot.log`**(安装环境的 `/root`),不在目标机 `/var/log/`,
所以目标机 `/var/log/ks-post-*.log` 只有 **9 个**,这是**设计如此**,不是丢日志。

---

## OBS-2(`linux-tty --version` 会直接渲染 TUI)

新版 `linux-tty` 没有干净的 `--version` 输出(直接进菜单界面),要读版本看界面里的 `Version : vX.Y.Z`。
不影响功能,仅影响脚本化取版本。

---

## OBS-3(测试机上"grub timeout 为空"是查错,不是产品问题)

曾用 `grep '^set timeout='` 查 `/boot/efi/EFI/centos/grub.cfg` 得到空 ⇒ 实际是 **CentOS 7 的 `00_header` 会写成 `  set timeout=1`(行首两空格)**。
正确查法:`grep '^[[:space:]]*set timeout='`。镜像里 KS 的 sed/grep 早已改成容忍缩进 ✓。

---

## 已修复问题(留档)

| 日期 | 问题 | 修法 |
|---|---|---|
| 10-22 | `repodata` 的 `location` 缺 `Packages/` 前缀 ⇒ anaconda 报 `Error populating transaction` / `Errno 256` | `createrepo_c -o <ISO根> <ISO根>`(递归),并用 `yum --downloadonly install @core` 做真实事务验证 |
| 10-22 | `repodata` 与 `Packages/` 不一致(303 vs 604) | 每次重建后校验"repodata 里每个包都有对应文件" |
| 10-22 | `smartmontools` 装不上(`mailx` 硬依赖 + `-ivh` 遇"已安装"中止事务) | 改为 `rpm -Uvh --replacepkgs` 一个事务装全 3 个包 |
| 10-22 | `smartd` 默认自启(会告警) | `%post` 里 `systemctl disable --now smartd` |
| 10-22 | `crashkernel=auto` 5.4 内核不认 ⇒ kdump 每次开机 failed | 改 `crashkernel=128M` |
| 10-21 | 装完不弹介质,重启又进安装界面 | `reboot` → `reboot --eject` |
| 10-21 | 安装菜单默认项应为 Auto | `menu default` 放回 Auto / UEFI `set default="1"` |
| 10-19 | 3.10 内核缺失 | 加入 `kernel-3.10.0-1160.119.1` + headers/tools/tools-libs |
| 10-18 | `GRUB_TIMEOUT` 被 anaconda 覆盖回 5 秒 | `%post` 里自己 `grub2-mkconfig` 重建 + sed 兜底 |

---

## BUG-4(已在 1.0.162 修复):重装到"已有系统"的盘时报 parted EBUSY

| 项 | 内容 |
|---|---|
| 现象 | 安装到分区阶段崩溃,Anaconda 异常报告:<br>`IOError: Partition(s) 2 on /dev/sda have been written, but we have been unable to inform the kernel of the change, probably because it/they are in use. You should reboot now before making further changes.` |
| 触发条件 | **目标盘上已有旧系统**(旧 swap 已激活 / 旧 LVM VG 未关 / 旧 dm/md/multipath 映射未清)⇒ `parted` 写分区表 **EBUSY** |
| 为什么以前没暴露 | 之前测试都用**空白新盘**;现场是在**已装过系统的盘**上重装 |
| 修法(1.0.162) | `%pre` 里 `parted` 之前加:`swapoff -a` · `vgchange -an` · `dmsetup remove_all` · `mdadm --stop --scan` · `multipath -F` · `umount -f /dev/<disk>N` · `udevadm settle`;`mklabel gpt` 后再 `udevadm settle` + `partprobe` |
| 现场临时绕过 | 若手上还是老盘:在安装器里按 `2) shell` 执行 `swapoff -a; vgchange -an; dmsetup remove_all; partprobe /dev/sda`,然后 `3) Quit` → 重启重装;或直接先用 1.0.162 |

---

## ENV-1(ESXi 侧坑,非镜像缺陷,但现场必踩):VMX 里 `guestOS` 必须写 `centos7-64`(连字符)

| 项 | 内容 |
|---|---|
| 现象 | 在 ESXi/vSphere 里手工写 vmx 建 UEFI 虚机,开机 30 秒内触发 `MONITOR PANIC: vcpu-0:IOAPIC: regSelect=0x8`,虚机被打死 |
| 根因 | `guestOS = "centos7_64"`(下划线)**不是合法值** ⇒ ESXi 判成 `otherGuest` ⇒ **vHW21 下加载 32-bit EFI ROM**(`EFI2.7 32-bit` / `VMW201.00V.24504846.B32`)⇒ guest 起来即 panic |
| 正确写法 | `guestOS = "centos7-64"`(连字符)⇒ 加载 **64-bit EFI ROM**(`...B64`)⇒ UEFI 装机一次通过 |
| 已排除 | vCPU 数、e1000/vmxnet3、sata/scsi、`apic.xapic.enable`、SecureBoot、vHW 降级(vHW19 的 32-bit EFI 不 panic 但 anaconda 卡死花屏) |
| 现场建议 | vSphere UI 里选 **"CentOS 7 (64-bit)"** 即可,不要手写 vmx;必须手写时用 `centos7-64` |
| 验证 | 1.0.173 + `firmware=efi` + `centos7-64` + vHW21 + pvscsi:UEFI 零输入装机通过,ESP/GPT、`efibootmgr BootCurrent=CentOS`、`set timeout=1`、双内核 5 包、`eth0:eth0`、`/root` 干净、`systemctl --failed` 空 全 PASS |

---

# 2026-10-31 本轮回归(Ver1.0.175～1.0.179)

## BUG-5(已在 1.0.177 修复):Auto 分支依赖的候选盘列表被写进了 static 分支内

| 项 | 内容 |
|---|---|
| 现象 | **Auto 零输入装机 100% 失败**:屏幕停在 `Installation Destination (No disks selected)` + `Network configuration (Not connected)`,安装器静默等输入 |
| 根因 | 1.0.175 把"候选盘枚举(排除 removable/USB/Ventoy)"插进了 `if grep -q static` 分支**内部**;Auto 分支引用 `$alldisk` ⇒ 恒为空 ⇒ 打 `AUTO INSTALL ABORTED` + `exit 1`(%pre 的 exit 不阻止 anaconda)⇒ `/tmp/other.ks` 0 字节 |
| 修法 | 枚举整段移到 static/auto 两个分支**之前**;并在 `%pre` 末尾加 **`KS-SELFCHECK`**:`/tmp/other.ks` 为空则清屏打横幅 + 列块设备 + `exit 1`(不再静默) |
| 验证 | b177(BIOS)、u177(UEFI)零输入一次装通;`[pre] auto target disk = /dev/sda` + `[pre] /tmp/other.ks lines: 8` |

## BUG-6(已在 1.0.179 修复):`Select` 编号选盘把"盘名 容量"拆成两行

| 项 | 内容 |
|---|---|
| 现象 | 两块盘显示成 **4 条**:`1 sda / 2 120G / 3 sdb / 4 120G`;输 `2` 得到 `120G` ⇒ 永远 `invalid`(只能输盘名) |
| 根因 | `alldisk` 内容是 `"sda 120G sdb 120G"`(名字+容量成对),代码用 `tr ' ' '\n' \| cat -n` 把每个 token 拆成一行再编号 |
| 修法 | 改 `xargs -n2` 保持成对:`alldisk=$(echo $alldisk \| xargs -n2 \| cat -n)` ⇒ `1 sda 120G` / `2 sdb 120G` |
| 验证 | m180(手动 Select):输入 `2` → **`>>> install disk selected: input="2" -> device=/dev/sdb`**,系统装到 sdb(/boot 1G、/data 100G、/ 19G) |

## BUG-7(诊断确认,非装机阻断):`inst.nosave=all_ks` 使 `anaconda --help/--version` 抛 NameError

`/usr/sbin/anaconda` 的提前退出分支在 `from pyanaconda.flags import flags` 之前调用 `parseArguments()` ⇒ `flags.nosave_input_ks` → `NameError`。**只影响 `--help/--version`**,正常安装路径先 import 再 parse。**保留该参数**(作用是装完不把 ks 留在目标机)。

## ENV-2(ESXi 8.0.3):`serial0` 串口后端不工作

| 项 | 内容 |
|---|---|
| 现象 | `fileType="file"` → `serial.out` 建了但**永远 0 字节**;`fileType="network" tcp://host:port` → ESXi **从不发起连接**;guest 侧 UART 正常(`uart:16550A port:3F8 irq:4`,`echo > /dev/ttyS0` 返回 0) |
| 影响 | 不能用串口做装机取证(不是我们镜像的问题) |
| 替代 | ESXi 8 原生 VNC 被禁(`RemoteDisplay.vnc not allowed, use webmks ticket`)⇒ 用 `webmks ticket` 桥到本地 TCP 再 `vncdotool` 发键/截图(已验证可用) |

## ENV-3:装到非第一块盘时 BIOS 不会自动从该盘引导

`bios.bootOrder="hdd"` 只试第一块盘(0:0),OS 在 (0:1) 时报 `Operating System not found`。
现场处理:PhoenixBIOS(F2)→ Boot → Hard Drive → 把对应盘 `+` 提到首位 → F10(nvram 持久)。UEFI 无此问题(启动项按分区 GUID)。

#!/bin/bash
# 首次启动体检:校验 eth0 / 内核 / GRUB 超时 / 失败服务,生成装机报告,然后自我停用
LOG=/var/log/edge-firstboot.log; REP=/var/log/edge-install-report.txt
exec >> "$LOG" 2>&1; echo "==== $(date '+%F %T') firstboot ===="
mkdir -p /var/log
{
  echo "===== 装机报告 $(date '+%F %T') ====="
  echo "hostname : $(hostname)"
  echo "kernel   : $(uname -r)"
  echo "rpm kernel: $(rpm -q kernel 2>/dev/null | tr '\n' ' ')"
  echo "firmware : $( [ -d /sys/firmware/efi ] && echo UEFI || echo Legacy-BIOS )"
  echo "eth0     : $( [ -d /sys/class/net/eth0 ] && echo present || echo MISSING )"
  echo "links    : $(ip -br link 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  echo "nmcli    : $(nmcli -t -f NAME,DEVICE c show 2>/dev/null | tr '\n' ' ')"
  echo "grub(BIOS): $(grep -m1 '^[[:space:]]*set timeout=' /boot/grub2/grub.cfg 2>/dev/null | tr -d ' ')"
  echo "grub(UEFI): $(grep -m1 '^[[:space:]]*set timeout=' /boot/efi/EFI/centos/grub.cfg 2>/dev/null | tr -d ' ')"
  echo "failed   : $(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  echo "disks    :"; lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | sed 's/^/  /'
} > "$REP"
# 体检告警(只记录,不重启)
[ -d /sys/class/net/eth0 ] || echo "WARN: eth0 missing"
dk=$(grubby --default-kernel 2>/dev/null); [ -n "$dk" ] || dk=/boot/vmlinuz-$(uname -r)
[ -f "$dk" ] || echo "WARN: default kernel entry not found: $dk"
# 硬件巡检(有 check 就跑一次)
[ -x /usr/local/bin/check ] && /usr/local/bin/check -q >/dev/null 2>&1 || true
systemctl disable edge-firstboot.service >/dev/null 2>&1
echo "done"; exit 0

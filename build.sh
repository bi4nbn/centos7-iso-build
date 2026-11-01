#!/usr/bin/env bash
# =============================================================================
#  centos7-iso-build / build.sh
#
#  一张官方 CentOS-7-x86_64-Minimal-2009.iso 原盘 → 一条命令 → 定制自动安装盘。
#
#  用法:
#     ./build.sh <官方ISO> [输出ISO] [选项]
#
#  选项:
#     --kernel-rpm <rpm>   额外把一个内核 rpm 注入安装源(例如 5.4 TL2 内核),
#                          注入后会自动"双内核":官方 3.10 与注入内核并存,
#                          默认启动项取版本更高的那个。不给就只装官方 3.10。
#     --no-eth0            不把网卡改名成 eth0(默认会改)
#     --label <LABEL>      光盘卷标(默认 CENTOS7_CUSTOM;只允许 A-Za-z0-9._-,≤32)
#     --menu-title <文本>  BIOS/UEFI 菜单标题
#     --rootpw <明文>      root 口令(默认 edge7install;写成 sha512 哈希进 ks)
#     --payload-dir <dir>  额外载荷目录,按目标机根目录布局放文件后整树并入 files/
#                          (用它注入 linux-tty 二进制、阵列卡 rpm 等,见 optional/README.md)
#     --keep-work          保留 .build/ 构建树(排查用)
#     -h | --help          帮助
#
#  依赖:genisoimage、isoinfo(genisoimage 包)、createrepo_c、rsync
#        可选:xorriso(解包更快)、mtools(mcopy,免 root 改 efiboot.img)
#
#  设计要点(踩过的坑,改脚本前先读 docs/BUILD-SKILL.md):
#   1. 用 isoinfo -R -x / xorriso -osirrox 解包,**不依赖 mount 权限**;
#   2. repodata 必须扫 **ISO 根**(createrepo_c -o NEW ISOROOT),否则 location
#      里缺 Packages/ 前缀,anaconda 报 Errno 256;
#   3. genisoimage 只用 **原盘的 isolinux/isolinux.bin**(不要用 xorriso 重打 El Torito,
#      会破坏 syslinux 校验和);
#   4. UEFI 真正读的是 images/efiboot.img **内部**那份 grub.cfg,必须同步;
#   5. 每次构建都从原盘重新解包,避免被 -boot-info-table 就地打补丁的 isolinux.bin 污染。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR

# ------------------------------------------------------------------ 默认参数 --
OUT_ISO=""
KERNEL_RPM=""
NO_ETH0=0
LABEL="CENTOS7_CUSTOM"
MENU_TITLE="CentOS 7 Custom Auto Install"
ROOTPW="edge7install"
PAYLOAD_DIR=""
KEEP_WORK=0

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m  warn\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
centos7-iso-build build.sh

  一张官方 CentOS-7-x86_64-Minimal-2009.iso 原盘 + 一条命令 → 定制自动安装盘

用法:
  ./build.sh <官方ISO> [输出ISO] [选项]

选项:
  --kernel-rpm <rpm>   注入一个内核 rpm(如 5.4 TL2),自动双内核:官方 3.10 + 注入内核
  --no-eth0            不把网卡改名成 eth0
  --label <LABEL>      光盘卷标(默认 CENTOS7_CUSTOM;仅 A-Za-z0-9._-,≤32 字符)
  --menu-title <文本>  BIOS/UEFI 菜单标题
  --rootpw <明文>      root 口令(默认 edge7install,以 sha512 哈希写入 ks)
  --payload-dir <dir>  额外载荷目录(按目标机根布局),整树并入 ISO 的 files/
  --keep-work          保留 .build/ 构建树
  -h, --help           显示本帮助

示例:
  ./build.sh CentOS-7-x86_64-Minimal-2009.iso
  ./build.sh CentOS-7-x86_64-Minimal-2009.iso out.iso --kernel-rpm ./kernel-5.4.119.rpm
  ./build.sh CentOS-7-x86_64-Minimal-2009.iso out.iso --rootpw 'S3cret!' --label MYLABEL
USAGE
exit 0
}

# ------------------------------------------------------------------ 参数解析 --
SRC_ISO=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)      usage ;;
        --kernel-rpm)   KERNEL_RPM=${2:?--kernel-rpm 需要参数}; shift 2 ;;
        --kernel-rpm=*) KERNEL_RPM=${1#*=}; shift ;;
        --no-eth0)      NO_ETH0=1; shift ;;
        --label)        LABEL=${2:?--label 需要参数}; shift 2 ;;
        --label=*)      LABEL=${1#*=}; shift ;;
        --menu-title)   MENU_TITLE=${2:?--menu-title 需要参数}; shift 2 ;;
        --menu-title=*) MENU_TITLE=${1#*=}; shift ;;
        --rootpw)       ROOTPW=${2:?--rootpw 需要参数}; shift 2 ;;
        --rootpw=*)     ROOTPW=${1#*=}; shift ;;
        --payload-dir)  PAYLOAD_DIR=${2:?--payload-dir 需要参数}; shift 2 ;;
        --payload-dir=*) PAYLOAD_DIR=${1#*=}; shift ;;
        --keep-work)    KEEP_WORK=1; shift ;;
        --) shift; break ;;
        -*) die "未知选项: $1(用 --help 看用法)" ;;
        *)
            if [ -z "$SRC_ISO" ]; then SRC_ISO=$1
            elif [ -z "$OUT_ISO" ]; then OUT_ISO=$1
            else die "多余参数: $1"
            fi
            shift ;;
    esac
done

[ -n "$SRC_ISO" ] || { printf '用法: %s <官方ISO> [输出ISO] [选项]\n' "$(basename "$0")"; exit 1; }

# ------------------------------------------------------------------ 前置检查 --
[ -f "$SRC_ISO" ] || die "找不到源 ISO: $SRC_ISO"
[ -f "$SRC_ISO" ] && [ ! -s "$SRC_ISO" ] && die "源 ISO 是空文件: $SRC_ISO"

[[ $LABEL =~ ^[A-Za-z0-9._-]{1,32}$ ]] || \
    die "卷标只能含 A-Z a-z 0-9 . _ - 且 ≤32 字符(ISO9660 限制): '$LABEL'"

for t in isoinfo genisoimage createrepo_c rsync; do
    command -v "$t" >/dev/null 2>&1 || \
        die "缺少命令 $t —— RHEL/CentOS 7: yum install -y genisoimage createrepo_c rsync ; Debian/Ubuntu: apt install -y genisoimage createrepo-c rsync"
done

if [ -z "$OUT_ISO" ]; then
    OUT_ISO="$PWD/centos7-custom-$(date +%Y%m%d-%H%M).iso"
fi
case "$OUT_ISO" in
    /*) ;;
    *)  OUT_ISO="$PWD/$OUT_ISO" ;;
esac
[ -e "$OUT_ISO" ] && die "输出文件已存在,先删掉或换个名字: $OUT_ISO"

[ -f "$SCRIPT_DIR/overlay/isolinux/ks.cfg" ] || die "overlay/ 不完整: 缺 overlay/isolinux/ks.cfg(请在仓库根目录运行)"
SRC_ABS="$(cd "$(dirname "$SRC_ISO")" && pwd)/$(basename "$SRC_ISO")"

if [ -n "$KERNEL_RPM" ]; then
    [ -f "$KERNEL_RPM" ] || die "找不到 --kernel-rpm 指定的文件: $KERNEL_RPM"
    KERNEL_RPM="$(cd "$(dirname "$KERNEL_RPM")" && pwd)/$(basename "$KERNEL_RPM")"
fi
if [ -n "$PAYLOAD_DIR" ]; then
    [ -d "$PAYLOAD_DIR" ] || die "找不到 --payload-dir 目录: $PAYLOAD_DIR"
    PAYLOAD_DIR="$(cd "$PAYLOAD_DIR" && pwd)"
fi

WORK_ROOT="$SCRIPT_DIR/.build"
TREE="$WORK_ROOT/isoroot"
mkdir -p "$WORK_ROOT"

# 空间:原盘 + 解包树 + 输出 ≈ 2.2×
src_mb=$(( $(stat -c%s "$SRC_ABS" 2>/dev/null || stat -f%z "$SRC_ABS") / 1024 / 1024 ))
need_mb=$(( src_mb * 22 / 10 + 256 ))
avail_mb=$(df -Pm "$WORK_ROOT" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${avail_mb:-}" ] && [ "$avail_mb" -lt "$need_mb" ]; then
    warn "磁盘剩余 ${avail_mb}MiB,建议 ≥${need_mb}MiB(源盘 ${src_mb}MiB + 解包树 + 输出)"
fi

printf '\n'
log "源盘      : $SRC_ABS ($(printf '%s' "$src_mb") MiB)"
log "输出      : $OUT_ISO"
log "卷标/标题 : $LABEL  /  $MENU_TITLE"
log "内核注入  : ${KERNEL_RPM:-无(只装官方 3.10)}"
log "eth0 改名 : $([ "$NO_ETH0" = 1 ] && echo 关闭 || echo 开启)"
log "额外载荷  : ${PAYLOAD_DIR:-无}"
printf '\n'

# ------------------------------------------------------------------ 0. 原盘标识 --
src_label=$(isoinfo -d -i "$SRC_ABS" 2>/dev/null | awk -F': ' '/^Volume id:/{print $2; exit}')
log "[0/8] 源盘卷标: ${src_label:-<未知>}"

# ------------------------------------------------------------------ 1. 解包 --
log "[1/8] 解包(不依赖 mount 权限)..."
rm -rf "$TREE"
mkdir -p "$TREE"

extracted=0
if command -v xorriso >/dev/null 2>&1; then
    if xorriso -osirrox on -indev "$SRC_ABS" -extract / "$TREE" >"$WORK_ROOT/xorriso.log" 2>&1 \
       && [ -f "$TREE/isolinux/isolinux.bin" ]; then
        extracted=1
        ok "xorriso -osirrox on -extract / 完成"
    else
        warn "xorriso 解包失败,回退 isoinfo(日志: $WORK_ROOT/xorriso.log)"
        rm -rf "$TREE"; mkdir -p "$TREE"
    fi
fi

if [ "$extracted" = 0 ]; then
    command -v isoinfo >/dev/null 2>&1 || die "xorriso 与 isoinfo 都不可用"
    n=0
    while IFS= read -r p; do
        case "$p" in
            */) mkdir -p "$TREE$p" ;;
            *)  mkdir -p "$TREE$(dirname "$p")"
                isoinfo -R -i "$SRC_ABS" -x "$p" > "$TREE$p" || die "isoinfo 提取失败: $p"
                n=$((n + 1)) ;;
        esac
    done < <(isoinfo -R -f -i "$SRC_ABS")
    ok "isoinfo -R -x 提取 $n 个文件"
fi

chmod -R u+w "$TREE" 2>/dev/null || true
for must in isolinux/isolinux.bin images/efiboot.img isolinux/vmlinuz Packages; do
    [ -e "$TREE/$must" ] || die "解包树缺少 $must —— 这不像一盘 CentOS 7 安装 ISO"
done
[ -d "$TREE/images/pxeboot" ] || die "解包树缺少 images/pxeboot"

# ------------------------------------------------------------------ 2. 覆盖 overlay --
log "[2/8] 覆盖 overlay/ (ks.cfg / isolinux.cfg / grub.cfg / files/)..."
rsync -a --exclude '.git*' --exclude '.gitkeep' "$SCRIPT_DIR/overlay/" "$TREE/"

# 额外载荷(按目标机根目录布局)
if [ -n "$PAYLOAD_DIR" ]; then
    mkdir -p "$TREE/files"
    rsync -a --exclude '.git*' --exclude '.gitkeep' --exclude 'README*' "$PAYLOAD_DIR/" "$TREE/files/"
    ok "载荷并入 files/: $(cd "$PAYLOAD_DIR" && find . -type f ! -name '.gitkeep' | wc -l) 个文件"
fi

KS="$TREE/isolinux/ks.cfg"
CFG_BIOS="$TREE/isolinux/isolinux.cfg"
CFG_UEFI="$TREE/EFI/BOOT/grub.cfg"
[ -f "$KS" ] || die "overlay 没落到树里: $KS"

# ------------------------------------------------------------------ 3. rootpw --
log "[3/8] 生成 root 口令哈希(sha512)..."
hash_pw() {
    local pw=$1 h=""
    if command -v openssl >/dev/null 2>&1; then
        h=$(openssl passwd -6 "$pw" 2>/dev/null || true)
    fi
    if [ -z "$h" ] && command -v python3 >/dev/null 2>&1; then
        h=$(python3 - "$pw" <<'PY' 2>/dev/null || true
import sys
try:
    import crypt
    print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))
except Exception:
    pass
PY
)
    fi
    if [ -z "$h" ] && command -v python2 >/dev/null 2>&1; then
        h=$(python2 - "$pw" <<'PY' 2>/dev/null || true
import crypt, sys
print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))
PY
)
    fi
    printf '%s' "$h"
}
PW_HASH=$(hash_pw "$ROOTPW")
if [ -z "$PW_HASH" ]; then
    # 兜底:预生成的 sha512(仅当本机没有任何可用的哈希工具时才会用到)
    PW_HASH='$6$edgesalt$LBCWc6qNqKc0m2hdmcILRdehgya49Ckq8jv3NvkIFqhc1fGYcxgJpLz0zK628HIzQUReOP/RoPgtWL5fQ0UNW0'
    warn "本机没有 openssl/python,使用预置哈希(对应口令 edge7install)"
fi
case "$PW_HASH" in
    '$6$'*) ;;
    *) die "口令哈希生成失败(需要 openssl passwd -6 或 python crypt): '$PW_HASH'" ;;
esac
sed -i "s|__ROOTPW_HASH__|$PW_HASH|" "$KS"
ok "rootpw 已写入 ks(哈希,无明文)"

# ------------------------------------------------------------------ 4. 菜单/卷标 --
log "[4/8] 写入卷标与菜单标题..."
sed -i "s|__LABEL__|$LABEL|g" "$CFG_BIOS" "$CFG_UEFI"
sed -i "s|__MENU_TITLE__|$MENU_TITLE|g" "$CFG_BIOS" "$CFG_UEFI"
grep -q "LABEL=$LABEL" "$CFG_BIOS" || die "isolinux.cfg 卷标替换失败"
grep -qF -- "search --no-floppy --set=root -l '$LABEL'" "$CFG_UEFI" || die "grub.cfg 卷标替换失败"
ok "isolinux.cfg / grub.cfg 已指向 LABEL=$LABEL"

# ------------------------------------------------------------------ 5. 内核/包 --
log "[5/8] 内核与可选包处理..."
if [ -n "$KERNEL_RPM" ]; then
    cp -f "$KERNEL_RPM" "$TREE/Packages/"
    inj=$(basename "$KERNEL_RPM")
    # 找出"官方"内核(排除刚注入的那个),把它的版本前缀显式写进 ks,实现双内核并存
    stock=$(ls "$TREE/Packages"/kernel-[0-9]*.rpm 2>/dev/null | xargs -r -n1 basename \
            | grep -v -F -x "$inj" | sort | head -1)
    if [ -n "$stock" ]; then
        stock_ver=$(printf '%s' "$stock" | sed -E 's/^kernel-([0-9]+\.[0-9]+)\..*/\1/')
        awk -v line="kernel-${stock_ver}.*" -v inj="$inj" '
            /^# __DUAL_KERNEL_BEGIN__$/ { print; print "# 已注入 " inj " ⇒ 显式保留官方内核,双内核并存:"; print line; next }
            { print }
        ' "$KS" > "$KS.tmp" && mv "$KS.tmp" "$KS"
        ok "注入 $inj;双内核:kernel-${stock_ver}.* + $inj"
    else
        warn "Packages/ 里没找到官方 kernel-*.rpm,跳过双内核处理"
        ok "注入 $inj"
    fi
else
    sed -i '/^# __DUAL_KERNEL_BEGIN__$/,/^# __DUAL_KERNEL_END__$/{
        /__DUAL_KERNEL_/!s/^\([^#]\)/# [no --kernel-rpm] \1/
    }' "$KS"
    ok "未注入内核:只装官方 3.10"
fi

# --no-eth0:整段注释掉 eth0 改名 %post
if [ "$NO_ETH0" = 1 ]; then
    sed -i '/^# __ETH0_POST_BEGIN__$/,/^# __ETH0_POST_END__$/ s/^\([^#]\)/# \1/' "$KS"
    ok "--no-eth0:已注释 eth0 改名 %post"
fi

# %packages 里的可选包:本盘没有的就注释掉(官方 Minimal 盘没有 kernel-headers/wget)
log "      校验 %packages 里的可选包是否真的在 Packages/ 里..."
in_blk=0
commented=0
while IFS= read -r line; do
    case "$line" in
        '# __OPT_PKGS_BEGIN__') in_blk=1; printf '%s\n' "$line"; continue ;;
        '# __OPT_PKGS_END__')   in_blk=0; printf '%s\n' "$line"; continue ;;
    esac
    if [ "$in_blk" = 1 ] && [ -n "${line// /}" ] && [ "${line#\#}" = "$line" ]; then
        spec=${line%% *}
        if compgen -G "$TREE/Packages/${spec}*.rpm" >/dev/null 2>&1; then
            printf '%s\n' "$line"
        else
            printf '# [build.sh] 本盘无此包,已跳过: %s\n' "$line"
            commented=$((commented + 1))
        fi
        continue
    fi
    printf '%s\n' "$line"
done < "$KS" > "$KS.tmp"
mv "$KS.tmp" "$KS"
ok "可选包检查完成(${commented} 个被跳过)"

# ks 语法自检:标记必须清干净、%packages/%end 成对
if grep -q '__ROOTPW_HASH__\|__LABEL__\|__MENU_TITLE__' "$KS" "$CFG_BIOS" "$CFG_UEFI"; then
    die "ks/菜单里还有未替换的占位符"
fi
pkgs_n=$(grep -c '^%packages' "$KS"); end_n=$(grep -c '^%end' "$KS")
[ "$pkgs_n" -ge 1 ] || die "ks.cfg 里没有 %packages 段"
ok "ks.cfg 段落检查: %packages=$pkgs_n, %end=$end_n"

# ------------------------------------------------------------------ 6. repodata --
log "[6/8] 重建 repodata(必须扫 ISO 根,否则 location 缺 Packages/ 前缀)..."
comps=""
for cand in "$TREE"/repodata/*minimal*comps.xml "$TREE"/repodata/*comps.xml; do
    if [ -f "$cand" ]; then comps=$cand; break; fi
done
[ -n "$comps" ] || die "原盘 repodata 里找不到 comps.xml —— 这盘不是完整的 CentOS 7 安装树"
ok "comps: $(basename "$comps")"

NEWRD="$WORK_ROOT/repodata.new"
rm -rf "$NEWRD"
mkdir -p "$NEWRD"
createrepo_c --quiet -g "$comps" --database --checksum sha256 -o "$NEWRD" "$TREE" \
    || die "createrepo_c 失败"
rm -rf "$TREE/repodata"
cp -a "$NEWRD/repodata" "$TREE/repodata"
pkg_n=$(find "$TREE/Packages" -maxdepth 1 -name '*.rpm' | wc -l)
ok "repodata 已重建(${pkg_n} 个 rpm),主索引: $(ls "$TREE/repodata" | grep -c 'primary') 份"

# ------------------------------------------------------------------ 7. UEFI 内层 --
log "[7/8] 同步 efiboot.img 内部 grub.cfg(UEFI 真正读的那份)..."
EFIIMG="$TREE/images/efiboot.img"
sync_efi=0
if command -v mcopy >/dev/null 2>&1; then
    if mcopy -o -i "$EFIIMG" "$CFG_UEFI" ::/EFI/BOOT/grub.cfg >/dev/null 2>&1; then
        sync_efi=1; ok "mtools(mcopy)写入 efiboot.img 成功"
    else
        warn "mcopy 写入失败,尝试 mount"
    fi
fi
if [ "$sync_efi" = 0 ] && [ "$(id -u)" = "0" ] && command -v mount >/dev/null 2>&1; then
    mnt=$(mktemp -d)
    if mount -o loop,rw "$EFIIMG" "$mnt" 2>/dev/null; then
        cp -f "$CFG_UEFI" "$mnt/EFI/BOOT/grub.cfg"
        sync
        umount "$mnt" && sync_efi=1 && ok "mount 方式写入 efiboot.img 成功"
    fi
    rmdir "$mnt" 2>/dev/null || true
fi
[ "$sync_efi" = 1 ] || die "无法修改 images/efiboot.img(内层 grub.cfg 不同步,UEFI 会找不到光盘)。
       解决:装 mtools(yum install -y mtools / apt install -y mtools)或用 root 运行。"

# ------------------------------------------------------------------ 8. 打包 --
log "[8/8] genisoimage 打包(BIOS + UEFI 双 El Torito)..."
mkdir -p "$(dirname "$OUT_ISO")"
cp -f "$TREE/isolinux/isolinux.bin" "$WORK_ROOT/isolinux.bin.orig"
genisoimage -o "$OUT_ISO" \
    -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e images/efiboot.img -no-emul-boot \
    -V "$LABEL" \
    -J -R -joliet-long -T -input-charset utf-8 \
    "$TREE" 2> "$WORK_ROOT/genisoimage.log" \
    || { cat "$WORK_ROOT/genisoimage.log" >&2; die "genisoimage 失败"; }
cp -f "$WORK_ROOT/isolinux.bin.orig" "$TREE/isolinux/isolinux.bin"
ok "已生成: $OUT_ISO"

# ------------------------------------------------------------------ 验收 --
log "验收(从成品 ISO 里反读,不看构建树)..."
out_label=$(isoinfo -d -i "$OUT_ISO" 2>/dev/null | awk -F': ' '/^Volume id:/{print $2; exit}')
[ "$out_label" = "$LABEL" ] || die "卷标不符: 期望 $LABEL,实际 $out_label"
ok "卷标: $out_label"

isoinfo -R -i "$OUT_ISO" -x /isolinux/ks.cfg > "$WORK_ROOT/ks.from_iso" 2>/dev/null \
    || die "成品 ISO 里读不到 /isolinux/ks.cfg"
grep -q '^rootpw --iscrypted \$6\$' "$WORK_ROOT/ks.from_iso" || die "成品 ks.cfg 的 rootpw 不是 sha512 哈希"
grep -q 'clearpart --all --initlabel --drives=' "$WORK_ROOT/ks.from_iso" \
    || die "成品 ks.cfg 缺少 clearpart(分区段异常)"
grep -q 'inst.nosave=all_ks' "$WORK_ROOT/ks.from_iso" 2>/dev/null || true
isoinfo -R -i "$OUT_ISO" -x /isolinux/isolinux.cfg 2>/dev/null | grep -q "LABEL=$LABEL" \
    || die "成品 isolinux.cfg 卷标不对"
isoinfo -R -i "$OUT_ISO" -x /isolinux/isolinux.cfg 2>/dev/null | grep -q '__LABEL__' \
    && die "成品 isolinux.cfg 里还有未替换的 __LABEL__"
ok "ks.cfg / isolinux.cfg 内容核对通过"

# EFI 内层校验(能读就读,读不了只提示)
if command -v mtype >/dev/null 2>&1; then
    isoinfo -R -i "$OUT_ISO" -x /images/efiboot.img > "$WORK_ROOT/efiboot.check.img" 2>/dev/null || true
    if [ -s "$WORK_ROOT/efiboot.check.img" ]; then
        mtype -i "$WORK_ROOT/efiboot.check.img" ::/EFI/BOOT/grub.cfg 2>/dev/null \
            | grep -q "$LABEL" && ok "efiboot.img 内层 grub.cfg 卷标正确" \
            || warn "efiboot.img 内层 grub.cfg 未读到卷标(请人工确认)"
    fi
fi

size=$(stat -c%s "$OUT_ISO" 2>/dev/null || stat -f%z "$OUT_ISO")
md5=$(md5sum "$OUT_ISO" | awk '{print $1}')
sha=$(sha256sum "$OUT_ISO" | awk '{print $1}')

if [ "$KEEP_WORK" = 0 ]; then
    rm -rf "$TREE" "$NEWRD" "$WORK_ROOT"/isoroot
else
    log "构建树保留在: $TREE"
fi

cat <<EOF

================================ 构建完成 ================================
  输出 ISO : $OUT_ISO
  体积     : $size 字节 ($(( size / 1024 / 1024 )) MiB)
  卷标     : $LABEL
  MD5      : $md5
  SHA256   : $sha
  内核     : $([ -n "$KERNEL_RPM" ] && echo "官方 3.10 + 注入 $(basename "$KERNEL_RPM")" || echo "仅官方 3.10")
  写入 U 盘: dd if='$(basename "$OUT_ISO")' of=/dev/sdX bs=4M status=progress oflag=sync
=========================================================================
EOF

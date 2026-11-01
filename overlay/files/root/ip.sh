#!/bin/bash
# CentOS7 Interactive Static Network Config Script
# Fix subshell array lost bug | Accurate UP detect | No empty interface
# Pure ip addr | Number select
#
# 2026-10 修订(按只读审查结论实施):
#   1) 不再执行 stty sane —— 实测它把 tty 的 erase 从 ^H 改回 ^?、并额外打开 brkint
#      (SOL/串口上的 BREAK 会变成 SIGINT)。交互已统一用 read -e,readline 自己认 ^H/^?。
#   2) IP/掩码/网关用 CentOS7 自带 ipcalc 校验,失败重问;3 次仍不合法则安全退出,
#      不写任何文件。掩码同时接受 24 与 255.255.255.0(前者用 ipcalc --netmask 换算)。
#   3) 备份挪到 /var/backups/ifcfg(700/600,/root 必须干净)。放在 /etc/sysconfig/network-scripts 下的
#      ifcfg-x.bak.<时间戳> 不会被 initscripts 忽略(它只丢弃以 .bak 结尾的名字),
#      会被 network 服务当成第二个 ifcfg 再应用一次。
#   4) 原 ifcfg 含 SLAVE/MASTER/BONDING_OPTS/VLAN/BRIDGE/TEAM_MASTER 或特殊 TYPE 直接拒绝。
#   5) 只 ifdown/ifup 目标网卡(NetworkManager 活跃时走 nmcli),不再 restart network 一刀切。
#   6) 原有 DNS(resolv.conf / 原 ifcfg)就保留:写 PEERDNS=no 并保留 DNS1/DNS2,
#      不无条件覆盖 /etc/resolv.conf。
#   7) 写出的 ifcfg 带 NM_CONTROLLED=yes:现场要求 NetworkManager 接管这块网卡,
#      所以生效优先走 nmcli(NM 没跑时才退回 ifdown/ifup),不再出现
#      "ifup 被 is_nm_handling 短路成什么都没做"。
#   8) 启动时把历史遗留的 ifcfg-*.<备份后缀> 从 network-scripts 目录挪到 /var/backups/ifcfg。
#   9) 只切换目标网卡(NM 活跃走 nmcli,否则 ifdown/ifup;失败最多重试 3 次),
#      不重启整个网络服务;结论只有一行 OK/FAILED。
#  10) 界面精简:只问 3 个输入(网卡 / IP(可带 /前缀)/ 网关可空),不再有任何多余话术;
#      没带 /前缀时按老习惯再问一次掩码(24 或点分十进制)。
set +e

# Ctrl-C / SIGTERM:干净退出(后面写临时文件时挂的 EXIT trap 会把它删掉;
# 真正落盘的只有 mv 那一步,原子替换,不会留半写的 ifcfg)。
trap 'exit 130' INT TERM

# Check root permission
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must run as root."
    exit 1
fi

# ---- 终端设置(串口/SOL/VGA 下退格键都能用)----
# 带外客户端(IPMI SOL 等)的退格常发 ^H(0x08),而 tty 默认 erase 是 ^?(0x7F)。
# 解决办法:交互读取统一用 readline(read -e),它对 ^H/^? 都认,还能整行编辑。
# 这里**故意不执行 stty sane**:实测它会把 erase 改回 ^? 并打开 brkint,反而破坏本修复。
case "${TERM:-}" in
    ""|dumb|unknown)
        case "$(tty 2>/dev/null)" in
            /dev/ttyS*|/dev/ttyAMA*) export TERM=vt100 ;;
            *)                        export TERM=linux ;;
        esac
        ;;
esac
# TERM 有值但 terminfo 库里没有(例如环境导入了不存在的类型)时,read -e/readline 会
# 退化成不回显。infocmp 由 @core 的 ncurses 提供(已核对 RPM 文件清单);查不到就退回 vt100。
infocmp "${TERM:-vt100}" >/dev/null 2>&1 || export TERM=vt100

# CentOS 7 的 ipcalc 由 initscripts 提供(/bin/ipcalc);没有它就不猜,直接拒绝运行
IPCALC=$(command -v /bin/ipcalc 2>/dev/null || command -v ipcalc 2>/dev/null)
if [ -z "${IPCALC}" ]; then
    echo "ERROR: ipcalc not found (on CentOS 7 it is provided by initscripts)."
    exit 1
fi

IFCFG_DIR=/etc/sysconfig/network-scripts
BAK_DIR=/var/backups/ifcfg
MAX_TRIES=3

# 老版本本脚本 / 菜单会把备份写成 ${IFCFG_DIR}/ifcfg-<dev>.bak.<时间戳>。initscripts 的
# 忽略规则(/etc/rc.d/init.d/functions: __sed_discard_ignored_files)只丢弃以
# .bak/.old/.orig/.rpmnew/.rpmorig/.rpmsave **结尾** 的名字,`.bak.<时间戳>` 不在其中,
# 于是 network 服务会把它当成第二块网卡,而 ifup 经 need_config/source_config 又会用
# 旧文件里的 DEVICE=x 把同一个设备再配一遍。统一挪到 ${BAK_DIR}。
# 注意:不能简单搬 ifcfg-*.* —— VLAN 的合法配置名本身带点(ifcfg-eth0.100)。
migrate_ifcfg_backups() {
    local f base
    install -d -m 700 "${BAK_DIR}" 2>/dev/null || return 0
    # 上一次被 Ctrl-C 打断时可能留下隐藏临时 ifcfg(.ifcfg-x.new.<pid>):它不会被
    # ifcfg-* 匹配到,但还是清掉,保持 network-scripts 目录干净。
    rm -f "${IFCFG_DIR}"/.ifcfg-*.new.* 2>/dev/null
    # 兼容上一版:老路径 /root/ifcfg-backup 里的备份挪过来,并把旧目录从 /root 删掉
    if [ -d /root/ifcfg-backup ]; then
        mv -f /root/ifcfg-backup/* "${BAK_DIR}/" 2>/dev/null
        rmdir /root/ifcfg-backup 2>/dev/null
    fi
    for f in "${IFCFG_DIR}"/ifcfg-*; do
        [ -f "$f" ] || continue
        base=${f##*/}
        case "$base" in
            ifcfg-lo) continue ;;
            *~|*.bak|*.old|*.orig|*.rpmnew|*.rpmorig|*.rpmsave) ;;
            *.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
            *) continue ;;   # 正常配置(含 ifcfg-eth0.100 这类 VLAN)一律不动
        esac
        mv -f "$f" "${BAK_DIR}/" 2>/dev/null
    done
}
migrate_ifcfg_backups

# ---- 校验函数 ----
# 合法 IPv4 地址(ipcalc -c)
is_ipv4() {
    "${IPCALC}" -c "$1" >/dev/null 2>&1
}

# 掩码:允许 24 (1-32) 或点分十进制;点分用 ipcalc --prefix 验证
is_mask_input() {
    local m=$1
    if [[ ${m} =~ ^[0-9]{1,2}$ ]]; then
        [ "${m}" -ge 1 ] && [ "${m}" -le 32 ] && return 0
        return 1
    fi
    "${IPCALC}" --prefix "${IPADDR}" "${m}" >/dev/null 2>&1
}

# 24 -> 255.255.255.0(已是点分则原样返回)
normalize_mask() {
    local m=$1
    if [[ ${m} =~ ^[0-9]{1,2}$ ]]; then
        "${IPCALC}" --netmask "${IPADDR}/${m}" 2>/dev/null | sed -n 's/^NETMASK=//p'
    else
        echo "${m}"
    fi
}

# 带重试的输入:空行/非法值都重问,3 次仍不合法返回 1(调用方安全退出,不写文件)。
# 注意:read -e 在"空行按 Ctrl-D"时返回 0 且变量为空,所以空值必须单独判。
ask_value() {
    local prompt=$1 var=$2 check=$3 val n=0 rc
    while [ "${n}" -lt "${MAX_TRIES}" ]; do
        n=$((n + 1))
        val=""
        read -r -e -p "${prompt}" val
        rc=$?
        if [ "${rc}" -ne 0 ]; then
            echo "  Read failed (rc=${rc}) - try again (${n}/${MAX_TRIES})."
            continue
        fi
        if [ -z "${val}" ]; then
            echo "  Empty input - try again (${n}/${MAX_TRIES})."
            continue
        fi
        if ! "${check}" "${val}"; then
            echo "  Invalid value: ${val} - try again (${n}/${MAX_TRIES})."
            continue
        fi
        printf -v "${var}" '%s' "${val}"
        return 0
    done
    return 1
}

abort_no_write() {
    echo "ERROR: too many invalid inputs - nothing has been changed."
    exit 1
}

# 由"网络地址"推导默认网关 = 网络地址 + 1,逐段进位处理。
#   10.0.0.0      -> 10.0.0.1
#   20.120.134.128-> 20.120.134.129
#   198.51.100.0  -> 198.51.100.1
#   /32 的 10.0.0.255 -> 10.0.1.0(进位;调用方对 /31、/32 会直接不猜)
# $1 = ipcalc --network 得到的点分网络地址。
derive_gateway() {
    local net=$1 o1 o2 o3 o4
    case "${net}" in
        *.*.*.*) ;;
        *) return 1 ;;
    esac
    IFS=. read -r o1 o2 o3 o4 <<< "${net}"
    o4=$((o4 + 1))
    if [ "${o4}" -gt 255 ]; then
        o4=0; o3=$((o3 + 1))
        if [ "${o3}" -gt 255 ]; then
            o3=0; o2=$((o2 + 1))
            if [ "${o2}" -gt 255 ]; then
                o2=0; o1=$((o1 + 1))
                [ "${o1}" -le 255 ] || return 1
            fi
        fi
    fi
    echo "${o1}.${o2}.${o3}.${o4}"
}

echo "================= NETWORK CONFIG (static) ================="
echo "Interfaces:"

# 初始化网卡数组(进程替换避免子 Shell 丢数组);去掉 @父设备 后缀并剔除虚拟口
IF_LIST=()
INDEX=1
while read -r NIC_NAME; do
    NIC_NAME="${NIC_NAME%%@*}"
    case "${NIC_NAME}" in
        ""|lo|docker*|veth*|virbr*|br-*|tun*|tap*|vnet*|kube*|cali*|flannel*|cni*)
            continue ;;
    esac
    state=$(cat "/sys/class/net/${NIC_NAME}/operstate" 2>/dev/null)
    [ -n "${state}" ] || state=unknown
    printf "  %d. %-16s link=%s\n" "$INDEX" "$NIC_NAME" "$state"
    IF_LIST+=("${NIC_NAME}")
    ((INDEX++))
done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}')

# ---- 输入 1/3:网卡 ----
read -r -e -p "Select interface number: " SEL_NUM
if ! [[ "${SEL_NUM}" =~ ^[1-9][0-9]*$ ]] || [ "${#SEL_NUM}" -gt 3 ]; then
    echo "ERROR: invalid interface number."
    exit 1
fi
ARR_INDEX=$((SEL_NUM - 1))
if [[ ${ARR_INDEX} -lt 0 || ${ARR_INDEX} -ge ${#IF_LIST[@]} ]]; then
    echo "ERROR: interface number out of range."
    exit 1
fi
NIC="${IF_LIST[${ARR_INDEX}]}"
CFG_FILE="${IFCFG_DIR}/ifcfg-${NIC}"
if [[ ! -f "${CFG_FILE}" ]]; then
    echo "ERROR: ${CFG_FILE} does not exist - this tool only edits an existing ifcfg."
    exit 1
fi

# ---- 类型保护:bond/vlan/bridge/team 成员绝不按普通以太网改写 ----
if grep -Eq '^[[:space:]]*(SLAVE|MASTER|BONDING_OPTS|VLAN|BRIDGE|TEAM_MASTER)=' "${CFG_FILE}" \
   || grep -Eq '^[[:space:]]*TYPE=[[:space:]]*"?(Vlan|Bridge|Bond|Team|IPSEC|IPIP|GRE)' "${CFG_FILE}"; then
    echo "ERROR: ${NIC} is a bond/vlan/bridge/team member or a special TYPE - refusing to touch it."
    echo "       Nothing was changed."
    exit 1
fi

# ---- 输入 2/3:IP(可带 /前缀,如 10.0.0.5/24);没带前缀就到后面再问一次掩码 ----
IPADDR=""
NETMASK=""
IP_TRY=0
IP_OK=0
while [ "${IP_TRY}" -lt "${MAX_TRIES}" ]; do
    IP_TRY=$((IP_TRY + 1))
    IPADDR=""; NETMASK=""
    read -r -e -p "IP address (CIDR or IP; prefix optional, e.g. 10.0.0.5/24): " _ip
    _rc=$?
    if [ "${_rc}" -ne 0 ]; then
        echo "  Read failed (rc=${_rc}) - try again (${IP_TRY}/${MAX_TRIES})."
        continue
    fi
    if [ -z "${_ip}" ]; then
        echo "  Empty input - try again (${IP_TRY}/${MAX_TRIES})."
        continue
    fi
    case "${_ip}" in
        */*)
            _addr="${_ip%%/*}"
            _pfx="${_ip##*/}"
            if ! is_ipv4 "${_addr}"; then
                echo "  Invalid address: ${_addr} - try again (${IP_TRY}/${MAX_TRIES})."
                continue
            fi
            if [[ "${_pfx}" =~ ^[0-9]{1,2}$ ]]; then
                if [ "${_pfx}" -lt 1 ] || [ "${_pfx}" -gt 32 ]; then
                    echo "  Invalid prefix: /${_pfx} - try again (${IP_TRY}/${MAX_TRIES})."
                    continue
                fi
                _mask=$("${IPCALC}" --netmask "${_addr}/${_pfx}" 2>/dev/null | sed -n 's/^NETMASK=//p')
            else
                if "${IPCALC}" --prefix "${_addr}" "${_pfx}" >/dev/null 2>&1; then
                    _mask="${_pfx}"
                else
                    _mask=""
                fi
            fi
            if [ -z "${_mask}" ]; then
                echo "  Invalid prefix: /${_pfx} - try again (${IP_TRY}/${MAX_TRIES})."
                continue
            fi
            IPADDR="${_addr}"; NETMASK="${_mask}"; IP_OK=1
            ;;
        *)
            if is_ipv4 "${_ip}"; then
                IPADDR="${_ip}"; IP_OK=1
            else
                echo "  Invalid address: ${_ip} - try again (${IP_TRY}/${MAX_TRIES})."
                continue
            fi
            ;;
    esac
    [ "${IP_OK}" -eq 1 ] && break
done
[ "${IP_OK}" -eq 1 ] || abort_no_write

if [ -z "${NETMASK}" ]; then
    # 老习惯兼容:IP 没带 /前缀时单独问一次掩码(24 或 255.255.255.0),同样最多 3 次
    ask_value "Subnet mask (e.g. 24 or 255.255.255.0): " NETMASK is_mask_input || abort_no_write
    NETMASK="$(normalize_mask "${NETMASK}")"
    [ -n "${NETMASK}" ] || abort_no_write
fi

# ---- 输入 3/3:网关。默认值 = 网络地址 + 1(回车即用),'none' = 不配默认路由 ----
GW_SUGGEST=""
GW_NET=$("${IPCALC}" --network "${IPADDR}" "${NETMASK}" 2>/dev/null | sed -n 's/^NETWORK=//p')
GW_PFX=$("${IPCALC}" --prefix "${IPADDR}" "${NETMASK}" 2>/dev/null | sed -n 's/^PREFIX=//p')
if [ -n "${GW_PFX}" ] && [ "${GW_PFX}" -ge 31 ] 2>/dev/null; then
    # /31、/32 没有可用主机地址,不猜网关(只提示)
    echo "NOTE: /${GW_PFX} has no usable host address - no gateway is suggested."
elif [ -n "${GW_NET}" ]; then
    GW_SUGGEST="$(derive_gateway "${GW_NET}")"
fi

GATEWAY=""
GW_OK=0
GW_TRY=0
while [ "${GW_TRY}" -lt "${MAX_TRIES}" ]; do
    GW_TRY=$((GW_TRY + 1))
    GATEWAY=""
    if [ -n "${GW_SUGGEST}" ]; then
        read -r -e -p "Gateway [${GW_SUGGEST}] (Enter = use, 'none' = no gateway, 'auto' = same): " GATEWAY
    else
        read -r -e -p "Gateway (blank/'none' = no default route): " GATEWAY
    fi
    GW_RC=$?
    if [ "${GW_RC}" -ne 0 ]; then
        echo "  Read failed (rc=${GW_RC}) - try again (${GW_TRY}/${MAX_TRIES})."
        continue
    fi
    case "${GATEWAY}" in
        "")
            if [ -n "${GW_SUGGEST}" ]; then GATEWAY="${GW_SUGGEST}"; GW_OK=1; break; fi
            echo "WARNING: no gateway - the default route will not be configured."
            GW_OK=1; break ;;
        none|no|-)
            GATEWAY=""
            echo "WARNING: no gateway - the default route will not be configured."
            GW_OK=1; break ;;
        auto)
            GATEWAY="${GW_SUGGEST}"
            if [ -z "${GATEWAY}" ]; then
                echo "  Cannot derive a gateway for ${IPADDR}/${NETMASK} - type one."
                continue
            fi
            GW_OK=1; break ;;
    esac
    if is_ipv4 "${GATEWAY}"; then GW_OK=1; break; fi
    echo "  Invalid gateway: ${GATEWAY} - try again (${GW_TRY}/${MAX_TRIES})."
done
[ "${GW_OK}" -eq 1 ] || abort_no_write
[ -n "${GATEWAY}" ] && [ "${GATEWAY}" = "${IPADDR}" ] && echo "WARNING: gateway equals the IP address - double-check it."

if [ -n "${GATEWAY}" ] && \
   [ "$("${IPCALC}" --network "${GATEWAY}" "${NETMASK}" 2>/dev/null)" != \
     "$("${IPCALC}" --network "${IPADDR}"  "${NETMASK}" 2>/dev/null)" ]; then
    echo "WARNING: gateway ${GATEWAY} is not in ${IPADDR}/${NETMASK} - the default route may not work."
fi

# ---- DNS:有现成的就保留(PEERDNS=no 并把 DNS1/DNS2 留在 ifcfg 里),否则用阿里 DNS;静默 ----
EXISTING_DNS=$(
    {
        sed -n 's/^[[:space:]]*nameserver[[:space:]]\+//p' /etc/resolv.conf 2>/dev/null
        sed -n 's/^[[:space:]]*DNS[0-9]=//p' "${CFG_FILE}" 2>/dev/null
    } | tr -d '"' | awk '{print $1}' | awk 'NF && !seen[$0]++' | head -3 | paste -sd' ' -
)
DNS_BLOCK=""
if [ -n "${EXISTING_DNS}" ]; then
    DNS_BLOCK="PEERDNS=no"
    _dns_i=0
    for _dns in ${EXISTING_DNS}; do
        _dns_i=$((_dns_i + 1))
        [ "${_dns_i}" -le 2 ] || break
        DNS_BLOCK="${DNS_BLOCK}
DNS${_dns_i}=${_dns}"
    done
    unset _dns _dns_i
else
    DNS_BLOCK="PEERDNS=yes
DNS1=223.6.6.6
DNS2=223.5.5.5"
fi
GATEWAY_BLOCK=""
[ -n "${GATEWAY}" ] && GATEWAY_BLOCK="GATEWAY=${GATEWAY}"

# ---- 备份(静默 700/600)+ 原子写入 ----
install -d -m 700 "${BAK_DIR}" || { echo "ERROR: cannot create ${BAK_DIR} - nothing was changed."; exit 1; }
BAK_FILE="${BAK_DIR}/ifcfg-${NIC}.$(date +%Y%m%d_%H%M%S)"
cp -a "${CFG_FILE}" "${BAK_FILE}" || { echo "ERROR: backup failed - nothing was changed."; exit 1; }
chmod 600 "${BAK_FILE}"

TMP_CFG="${IFCFG_DIR}/.ifcfg-${NIC}.new.$$"
trap 'rm -f "${TMP_CFG}"' EXIT
cat > "${TMP_CFG}" <<EOF
TYPE=Ethernet
BOOTPROTO=static
NAME=${NIC}
DEVICE=${NIC}
ONBOOT=yes
NM_CONTROLLED=yes
IPADDR=${IPADDR}
NETMASK=${NETMASK}
${GATEWAY_BLOCK}
${DNS_BLOCK}
EOF
chmod 644 "${TMP_CFG}"
mv -f "${TMP_CFG}" "${CFG_FILE}" || { echo "ERROR: cannot install ${CFG_FILE} - the original is untouched."; exit 1; }

# ---- 只切换目标网卡:NM 主导(NetworkManager 活跃时走 nmcli),否则退回 ifdown/ifup ----
# 不 restart network / NetworkManager 一刀切;失败最多重试 3 次;结论只有一行 OK/FAILED。
# 每次生效前现查 NM 状态(装机过程中它可能刚被拉起 / 刚被停掉)。

# 让目标网卡的配置真正生效:$1 = 网卡名。
#   NM 活跃:reload -> 按 DEVICE 找连接名(找不到就用网卡名,我们写的 ifcfg 里 NAME=$dev)-> con up
#   NM 没跑:退回 ifdown/ifup(与历史行为一致,串口/最小系统下没有 NM 也能配网)
# 本次走的是哪条路记在 NM_ACTIVE 里,供 nic_ready 判定。
NM_ACTIVE=0
nic_apply() {
    local dev=$1 con
    if systemctl is-active --quiet NetworkManager; then
        NM_ACTIVE=1
        nmcli con reload >/dev/null 2>&1
        con=$(nmcli -t -f NAME,DEVICE con show | awk -F: -v d="$dev" '$2==d{print $1; exit}')
        [ -n "$con" ] || con="$dev"          # 我们写入的 ifcfg 里 NAME=$dev,通常就是它
        nmcli con up "$con" >/dev/null 2>&1
    else
        NM_ACTIVE=0
        ifdown "$dev" 2>/dev/null
        ifup "$dev" >/dev/null 2>&1
    fi
}

# 就绪判定:必须真的拿到 IPv4;NM 路径下还要求 nmcli dev status 里该设备为 connected。
nic_ready() {
    local dev=$1 ip4 st
    ip4=$(ip -4 -o addr show "$dev" 2>/dev/null | awk '{print $4}' | head -1)
    [ -n "${ip4}" ] || return 1
    if [ "${NM_ACTIVE}" -eq 1 ]; then
        st=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | awk -F: -v d="$dev" '$1==d{print $2; exit}')
        [ "${st}" = "connected" ] || return 1
    fi
    return 0
}

if systemctl is-active --quiet NetworkManager; then
    echo "Applying config on ${NIC} (nmcli) ..."
else
    echo "Applying config on ${NIC} (ifdown/ifup) ..."
fi
nic_apply "${NIC}"
_i=0
while [ "${_i}" -lt "${MAX_TRIES}" ]; do
    nic_ready "${NIC}" && break
    _i=$((_i + 1))
    sleep 2
    nic_apply "${NIC}"
done
if nic_ready "${NIC}"; then
    _ip4=$(ip -4 -o addr show "${NIC}" 2>/dev/null | awk '{print $4}' | head -1)
    echo "OK: ${NIC} is up (${_ip4})"
else
    _ip4=$(ip -4 -o addr show "${NIC}" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -z "${_ip4}" ]; then
        echo "FAILED: ${NIC} has no IPv4 address after $((_i + 1)) attempt(s) (backup: ${BAK_FILE})"
    else
        _st=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | awk -F: -v d="${NIC}" '$1==d{print $2; exit}')
        echo "FAILED: ${NIC} has ${_ip4} but NetworkManager state is '${_st:-unknown}' after $((_i + 1)) attempt(s) (backup: ${BAK_FILE})"
    fi
    exit 1
fi

# ---- 连通性:最多一行 ----
PING_TARGET="${GATEWAY:-qq.com}"
if ping -c 2 -W 2 "${PING_TARGET}" >/dev/null 2>&1; then
    echo "PING: OK"
else
    echo "PING: FAILED"
fi

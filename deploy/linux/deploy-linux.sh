#!/usr/bin/env bash
# ============================================================
#  Linux 端 SSH Server 一键部署
#
#  在目标机器上执行：
#      sudo bash deploy-linux.sh
#
#  可选参数：
#      --port 2222          指定端口
#      --user alice         把公钥写入指定用户（默认当前 sudo 用户 + root）
#      --password           同时允许密码登录
#      --keys <文件>        指定公钥文件
#      --uninstall          卸载
#      --dry-run            只检查不修改
# ============================================================

set -uo pipefail

# ---------- 定位脚本自身与配套文件 ----------
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || echo "$SCRIPT_DIR")"

PORT=22
TARGET_USER=""
ALLOW_PASSWORD=0
KEYS_FILE=""
DO_UNINSTALL=0
DRY_RUN=0
# 允许连接的来源网段（空格分隔），空=不限制
ALLOW_FROM=""
# 限定可登录账号（空格分隔），空=不限制
ALLOW_USERS=""

# ---------- 输出 ----------
if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'
    C_STEP=$'\033[36m'; C_TIP=$'\033[35m'; C_OFF=$'\033[0m'
else
    C_OK=''; C_ERR=''; C_WARN=''; C_STEP=''; C_TIP=''; C_OFF=''
fi

STEP_N=0
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[OK]  %s%s\n'   "$C_OK"   "$*" "$C_OFF"; }
warn() { printf '%s[WARN] %s%s\n'  "$C_WARN" "$*" "$C_OFF"; }
err()  { printf '%s[ERR] %s%s\n'   "$C_ERR"  "$*" "$C_OFF"; }
tip()  { printf '%s[TIP] %s%s\n'   "$C_TIP"  "$*" "$C_OFF"; }
step() { STEP_N=$((STEP_N+1)); printf '\n%s[%d] %s%s\n' "$C_STEP" "$STEP_N" "$*" "$C_OFF"; }
die()  { err "$*"; say ""; err "部署中止。"; exit 1; }

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --port)      PORT="${2:-22}"; shift 2 ;;
        --user)      TARGET_USER="${2:-}"; shift 2 ;;
        --keys)      KEYS_FILE="${2:-}"; shift 2 ;;
        --password)  ALLOW_PASSWORD=1; shift ;;
        --uninstall) DO_UNINSTALL=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --allow-from)  ALLOW_FROM="${2:-}"; shift 2 ;;
        --allow-users) ALLOW_USERS="${2:-}"; shift 2 ;;
        -h|--help)
            sed -n '2,/^# =====/{/^# =====/!p}' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) err "未知参数：$1"; exit 1 ;;
    esac
done

# ---------- 权限检查 ----------
[ "$(id -u)" -eq 0 ] || die "需要 root 权限，请用 sudo 运行：sudo bash $0"

# ---------- 发行版识别 ----------
detect_distro() {
    DISTRO_ID=""; DISTRO_LIKE=""; DISTRO_VER=""
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="${ID:-}"; DISTRO_LIKE="${ID_LIKE:-}"; DISTRO_VER="${VERSION_ID:-}"
    elif [ -r /etc/redhat-release ]; then
        DISTRO_ID="rhel"
    fi

    PKG=""
    case "$DISTRO_ID" in
        debian|ubuntu|linuxmint|pop|kali|raspbian|elementary) PKG="apt" ;;
        rhel|centos|rocky|almalinux|ol|fedora|amzn)            PKG="dnf" ;;
        opensuse*|sles|suse)                                   PKG="zypper" ;;
        arch|manjaro|endeavouros)                              PKG="pacman" ;;
        alpine)                                                PKG="apk" ;;
        *)
            case " $DISTRO_LIKE " in
                *debian*|*ubuntu*) PKG="apt" ;;
                *rhel*|*fedora*|*centos*) PKG="dnf" ;;
                *suse*) PKG="zypper" ;;
                *arch*) PKG="pacman" ;;
                *) PKG="" ;;
            esac
            ;;
    esac
    # dnf 不存在时退回 yum
    if [ "$PKG" = "dnf" ] && ! command -v dnf >/dev/null 2>&1 && command -v yum >/dev/null 2>&1; then
        PKG="yum"
    fi
}

# ---------- 公钥收集 ----------
collect_keys() {
    local cands=()
    [ -n "$KEYS_FILE" ] && cands+=("$KEYS_FILE")
    cands+=("$KIT_ROOT/keys/authorized_keys")
    cands+=("$KIT_ROOT/keys/id_rsa.pub")
    cands+=("$SCRIPT_DIR/keys/authorized_keys")

    local f
    for f in "${cands[@]}"; do
        if [ -f "$f" ]; then
            local n
            n=$(grep -cE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null || echo 0)
            if [ "$n" -gt 0 ]; then
                FOUND_KEYS="$f"
                KEY_COUNT="$n"
                ok "读取到 $n 条公钥：$f"
                return 0
            fi
        fi
    done
    FOUND_KEYS=""; KEY_COUNT=0
    warn "未找到任何公钥文件，将跳过密钥写入"
    return 0
}

# ---------- 安装 openssh-server ----------
install_openssh() {
    if command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]; then
        ok "sshd 已存在：$({ command -v sshd || echo /usr/sbin/sshd; })"
        # 某些最小化系统只有客户端
        if [ ! -f /etc/ssh/sshd_config ]; then
            warn "未找到 /etc/ssh/sshd_config，仍尝试安装服务端包"
        else
            return 0
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        say "  [dry-run] 将使用 $PKG 安装 openssh-server"
        return 0
    fi

    say "  使用包管理器：$PKG"
    case "$PKG" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq 2>&1 | tail -3
            # openssh-server 通常已预装；确保存在
            apt-get install -y -qq openssh-server 2>&1 | tail -5
            ;;
        dnf|yum)
            $PKG install -y -q openssh-server 2>&1 | tail -5
            ;;
        zypper)
            zypper --non-interactive install openssh 2>&1 | tail -5
            ;;
        pacman)
            pacman -Sy --noconfirm openssh 2>&1 | tail -5
            ;;
        apk)
            apk add --no-cache openssh 2>&1 | tail -5
            ;;
        *)
            warn "无法识别包管理器，尝试直接使用现有 sshd"
            ;;
    esac

    if command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]; then
        ok "openssh-server 安装完成"
    else
        die "安装失败。请手动安装 openssh-server 后重试（离线环境请挂载系统安装盘或配置本地源）"
    fi
}

# ---------- 主机密钥 ----------
ensure_host_keys() {
    if [ "$DRY_RUN" -eq 1 ]; then say "  [dry-run] 将生成缺失的主机密钥"; return 0; fi

    if ssh-keygen -A 2>/dev/null; then
        ok "主机密钥就绪"
    else
        # 老版本无 -A 参数时逐个生成
        local t
        for t in rsa ecdsa ed25519; do
            local f="/etc/ssh/ssh_host_${t}_key"
            if [ ! -f "$f" ]; then
                ssh-keygen -q -t "$t" -f "$f" -N '' </dev/null 2>/dev/null && ok "生成 $t 主机密钥"
            fi
        done
    fi
}

# ---------- 写入公钥 ----------
install_keys_for_user() {
    local u="$1"
    local home
    home=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
    if [ -z "$home" ]; then
        warn "用户 $u 不存在，跳过"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        say "  [dry-run] 将写入 $home/.ssh/authorized_keys（用户 $u）"
        return 0
    fi

    local d="$home/.ssh"
    local f="$d/authorized_keys"
    mkdir -p "$d"
    touch "$f"

    # 去重追加
    local k added=0
    while IFS= read -r k; do
        case "$k" in
            ssh-*|ecdsa-*|sk-*)
                if ! grep -qxF "$k" "$f" 2>/dev/null; then
                    printf '%s\n' "$k" >> "$f"
                    added=$((added+1))
                fi
                ;;
        esac
    done < "$FOUND_KEYS"

    # 权限：.ssh 700，authorized_keys 600，属主为该用户
    chmod 700 "$d"
    chmod 600 "$f"
    chown -R "$u": "$d" 2>/dev/null || chown -R "$u" "$d" 2>/dev/null || true

    # SELinux 上下文（RHEL 系）
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R "$d" 2>/dev/null || true
    fi

    ok "用户 $u：追加 $added 条公钥 → $f"
}

# ---------- 配置 sshd ----------
configure_sshd() {
    local cfg=/etc/ssh/sshd_config
    [ -f "$cfg" ] || die "找不到 $cfg"

    if [ "$DRY_RUN" -eq 1 ]; then say "  [dry-run] 将修改 $cfg"; return 0; fi

    # 备份
    local bak="$cfg.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$cfg" "$bak"
    ok "已备份：$bak"
    BACKUP_CFG="$bak"

    # 使用独立 drop-in 更安全，但老版本不支持 Include，故直接改主配置
    # 策略：删除所有 Match 块之前的同名(无论是注释还是生效的)行，再在文件头插入唯一一条
    set_opt() {
        local key="$1" val="$2"
        local match_no
        match_no=$(grep -niE "^[[:space:]]*Match[[:space:]]" "$cfg" | head -1 | cut -d: -f1)
        [ -z "$match_no" ] && match_no=999999

        # 收集 Match 之前的所有同名行号（含被注释的），倒序删除
        local lines
        lines=$(grep -niE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]" "$cfg" \
                | cut -d: -f1 | awk -v m="$match_no" '$1 < m' | sort -rn)

        local n
        for n in $lines; do
            sed -i "${n}d" "$cfg"
        done

        # 在文件第一行之前插入全局设置
        sed -i "1i ${key} ${val}" "$cfg"
    }

    set_opt "Port"                   "$PORT"
    set_opt "PubkeyAuthentication"   "yes"
    set_opt "AuthorizedKeysFile"     ".ssh/authorized_keys"
    set_opt "PermitRootLogin"        "prohibit-password"
    if [ "$ALLOW_PASSWORD" -eq 1 ]; then
        set_opt "PasswordAuthentication" "yes"
    else
        set_opt "PasswordAuthentication" "no"
    fi

    # 公共机器上限定可登录账号
    if [ -n "$ALLOW_USERS" ]; then
        set_opt "AllowUsers" "$ALLOW_USERS"
        ok "已限定可登录账号：$ALLOW_USERS"
    else
        warn "未限定 AllowUsers（本机所有可用账号均可登录）"
    fi

    ok "配置已更新：$cfg"

    # 语法校验
    local sshd_bin testout
    if command -v sshd >/dev/null 2>&1; then
        sshd_bin=$(command -v sshd)
    else
        sshd_bin=/usr/sbin/sshd
    fi
    testout=$("$sshd_bin" -t 2>&1)
    if [ $? -ne 0 ]; then
        err "配置校验失败：$testout"
        cp -a "$bak" "$cfg"
        warn "已回滚配置"
        die "sshd_config 校验未通过"
    fi
    ok "配置语法正确"
}

# ---------- 防火墙 / SELinux ----------
configure_firewall() {
    if [ "$DRY_RUN" -eq 1 ]; then say "  [dry-run] 将放行端口 $PORT"; return 0; fi

    # 组装来源限制参数
    local from_args=()
    if [ -n "$ALLOW_FROM" ]; then
        local src
        for src in $ALLOW_FROM; do from_args+=("$src"); done
    fi

    # firewalld
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        if [ ${#from_args[@]} -eq 0 ]; then
            firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 \
                && firewall-cmd --reload >/dev/null 2>&1 \
                && ok "firewalld 已放行 TCP $PORT（未限制来源）" \
                || warn "firewalld 放行失败，请手动处理"
        else
            local s okcnt=0
            for s in "${from_args[@]}"; do
                # firewalld 的 rich rule 才能限定来源
                firewall-cmd --permanent --add-rich-rule=\
"rule family=\"ipv4\" source address=\"${s}\" port port=\"${PORT}\" protocol=\"tcp\" accept" \
                    >/dev/null 2>&1 && okcnt=$((okcnt+1))
            done
            firewall-cmd --reload >/dev/null 2>&1
            if [ "$okcnt" -gt 0 ]; then
                ok "firewalld 已放行 TCP $PORT，仅允许来源：$ALLOW_FROM"
            else
                warn "firewalld 规则添加失败，请手动处理"
            fi
        fi
        return 0
    fi

    # ufw
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        if [ ${#from_args[@]} -eq 0 ]; then
            ufw allow "${PORT}/tcp" >/dev/null 2>&1 \
                && ok "ufw 已放行 TCP $PORT（未限制来源）" \
                || warn "ufw 放行失败，请手动处理"
        else
            local s okcnt=0
            for s in "${from_args[@]}"; do
                ufw allow from "$s" to any port "$PORT" proto tcp >/dev/null 2>&1 && okcnt=$((okcnt+1))
            done
            if [ "$okcnt" -gt 0 ]; then
                ok "ufw 已放行 TCP $PORT，仅允许来源：$ALLOW_FROM"
            else
                warn "ufw 规则添加失败，请手动处理"
            fi
        fi
        return 0
    fi

    # nftables / iptables 仅在规则集存在时提示，不持久化
    if command -v nft >/dev/null 2>&1 && nft list tables 2>/dev/null | grep -q .; then
        if [ -n "$ALLOW_FROM" ]; then
            tip "检测到 nftables，请自行放行 TCP $PORT 并限定来源：$ALLOW_FROM"
        else
            tip "检测到 nftables 规则集，请确认已放行 TCP $PORT"
        fi
    fi

    ok "未检测到活动防火墙，跳过"
}

# ---------- 启动服务 ----------
start_service() {
    if [ "$DRY_RUN" -eq 1 ]; then say "  [dry-run] 将启动 sshd"; return 0; fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        sleep 1
        if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
            ok "systemd 服务已启动"
            return 0
        fi
        warn "systemd 启动失败，尝试直接拉起"
    fi

    if command -v service >/dev/null 2>&1; then
        service ssh restart >/dev/null 2>&1 || service sshd restart >/dev/null 2>&1 || true
        sleep 1
    fi

    if pgrep -x sshd >/dev/null 2>&1; then
        ok "sshd 进程运行中"
    else
        warn "未能确认 sshd 运行，请手动检查：systemctl status ssh"
    fi
}

# ---------- 自检 ----------
self_check() {
    local listen=0
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]" && listen=1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]" && listen=1
    fi

    if [ "$listen" -eq 1 ]; then
        ok "端口 $PORT 正在监听"
    else
        warn "端口 $PORT 未监听，请检查服务状态与配置"
    fi
}

# ---------- 卸载 ----------
do_uninstall() {
    step "卸载 SSH 服务"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop ssh 2>/dev/null || systemctl stop sshd 2>/dev/null || true
        systemctl disable ssh 2>/dev/null || systemctl disable sshd 2>/dev/null || true
        ok "服务已停止并取消开机启动"
    fi
    tip "是否卸载软件包请自行决定，本脚本不改动已安装包"
    tip "公钥与配置保留在 ~/.ssh 与 /etc/ssh（如需清除请手动删除）"
    exit 0
}

# ============================================================
# 主流程
# ============================================================
say ""
say "  ============================================================"
say "            Linux SSH 服务一键部署"
say "  ============================================================"
say "  主机   : $(hostname 2>/dev/null || echo unknown)"
say "  内核   : $(uname -r 2>/dev/null)"
say "  端口   : $PORT"
say "  认证   : $([ "$ALLOW_PASSWORD" -eq 1 ] && echo '公钥 + 密码' || echo '仅公钥')"
say "  模式   : $([ "$DRY_RUN" -eq 1 ] && echo '演练（不修改）' || echo '正式执行')"
say "  ============================================================"

detect_distro
say "  发行版 : ${DISTRO_ID:-unknown} ${DISTRO_VER}  (包管理器: ${PKG:-none})"

[ "$DO_UNINSTALL" -eq 1 ] && do_uninstall

step "安装 sshd"
install_openssh

step "生成主机密钥"
ensure_host_keys

step "写入授权公钥"
collect_keys
if [ "$KEY_COUNT" -gt 0 ]; then
    # 默认写入 root 与 sudo 发起者
    install_keys_for_user root
    SUDO_USER_REAL="${SUDO_USER:-}"
    if [ -n "$SUDO_USER_REAL" ] && [ "$SUDO_USER_REAL" != "root" ]; then
        install_keys_for_user "$SUDO_USER_REAL"
    fi
    if [ -n "$TARGET_USER" ]; then
        install_keys_for_user "$TARGET_USER"
    fi
    # 容器/云镜像常见默认用户
    for u in ubuntu ec2-user centos debian alpine; do
        if [ -n "$TARGET_USER" ] && [ "$u" = "$TARGET_USER" ]; then continue; fi
        if id "$u" >/dev/null 2>&1; then
            install_keys_for_user "$u"
        fi
    done
else
    warn "跳过密钥写入"
fi

step "配置 sshd"
BACKUP_CFG=""
configure_sshd

step "配置防火墙"
configure_firewall

step "启动服务"
start_service

step "连通性自检"
self_check

# ---------- 输出 ----------
say ""
say "  ============================================================"
say "                    部署完成"
say "  ============================================================"
say ""
say "  从其它机器连接："
say ""
IPS=$(ip -4 addr show 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2}' | grep -v '^127\.' || true)
if [ -n "$IPS" ]; then
    echo "$IPS" | while read -r ip; do
        say "    ssh ${SUDO_USER:-root}@${ip} -p ${PORT}"
    done
else
    say "    ssh ${SUDO_USER:-root}@<本机IP> -p ${PORT}"
fi
say ""
say "  授权公钥数：$KEY_COUNT"
say "  认证方式  ：$([ "$ALLOW_PASSWORD" -eq 1 ] && echo '公钥 + 密码' || echo '仅公钥（更安全）')"
[ -n "$BACKUP_CFG" ] && say "  配置备份  ：$BACKUP_CFG"
say ""
say "  常用排查："
say "    systemctl status ssh"
say "    journalctl -u ssh -n 50 --no-pager"
say ""
say "  ============================================================"
say ""

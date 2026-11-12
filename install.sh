#!/usr/bin/env bash
set +x

# 固定官方发布资产及其 SHA-256。升级时同时更新版本和摘要。
XRAY_VERSION=v26.11.9
XRAY_SHA256=b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82
HY2_VERSION=v2.13.0
HY2_SHA256=907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691
CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

prompt() {
    printf '%s' "$1" >&3
    IFS= read -r REPLY <&3 || die '终端输入已结束。'
}

menu() {
    while :; do
        printf '\n1. 安装 VLESS + TCP + XTLS Vision + TLS\n2. 安装 Hysteria 2 + QUIC + TLS（UDP）\n3. 同时部署 VLESS 和 Hysteria 2\n0. 退出\n' >&3
        prompt '请选择 [1/2/3/0]：'
        case "$REPLY" in
            1) selected_protocols=(vless); return ;;
            2) selected_protocols=(hy2); return ;;
            3) selected_protocols=(vless hy2); return ;;
            0) exit 0 ;;
            *) printf '请输入 1、2、3 或 0。\n' >&3 ;;
        esac
    done
}

select_protocol() {
    protocol=$1
    case "$protocol" in
        vless) protocol_name=VLESS; transport=TCP; version=$XRAY_VERSION ;;
        hy2) protocol_name='Hysteria 2'; transport=UDP; version=$HY2_VERSION ;;
    esac
    target="/opt/vps-proxy-$protocol"
    account="vps-proxy-$protocol"
    unit="vps-proxy-$protocol.service"
    unit_file="/etc/systemd/system/$unit"
}

normalize_host() {
    python3 - "$1" <<'PY'
import ipaddress
import re
import sys

host = sys.argv[1]
bracketed = host.startswith('[') and host.endswith(']')
if bracketed:
    host = host[1:-1]
if '%' in host:
    sys.exit(1)
try:
    ip = ipaddress.ip_address(host)
except ValueError:
    labels = host.removesuffix('.').lower().split('.')
    label = r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
    if (bracketed or len(host) > 254 or len(labels) < 2 or labels[-1].isdigit()
            or not all(re.fullmatch(label, part, re.ASCII) for part in labels)):
        sys.exit(1)
    print('.'.join(labels))
else:
    if (bracketed and ip.version != 6) or ip.is_unspecified or ip.is_multicast or ip.is_link_local or ip.is_loopback:
        sys.exit(1)
    if ip.version == 6 and ip.ipv4_mapped:
        sys.exit(1)
    print(ip.compressed)
PY
}

normalize_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )) || return 1
    printf '%d\n' "$((10#$1))"
}

uri_host() {
    if [[ "$1" == *:* ]]; then
        printf '[%s]' "$1"
    else
        printf '%s' "$1"
    fi
}

render_link() {
    local kind=$1 host=$2 port=$3 secret=$4 name=$5 pin=$6
    local authority query suffix scheme separator
    authority=$(uri_host "$host")
    case "$kind" in
        vless)
            scheme=vless
            suffix=''
            query='?type=tcp&encryption=none&flow=xtls-rprx-vision&security=tls'
            ;;
        hy2)
            scheme=hysteria2
            suffix=/
            query=''
            ;;
    esac
    if [[ -n "$name" ]]; then
        name=$(uri_host "$name")
        name=${name//:/%3A}
        name=${name//\[/%5B}
        name=${name//\]/%5D}
        separator='?'
        [[ -z "$query" ]] || separator='&'
        query+="${separator}sni=${name}"
    fi
    if [[ -n "$pin" ]]; then
        separator='?'
        [[ -z "$query" ]] || separator='&'
        query+="${separator}pcs=${pin}"
        if [[ "$kind" == hy2 ]]; then
            query+="&pinSHA256=${pin}"
        fi
    fi
    printf '%s://%s@%s:%s%s%s#VPS-%s\n' "$scheme" "$secret" "$authority" "$port" "$suffix" "$query" "$kind"
}

check_environment() {
    local cmd ID='' VERSION_ID=''
    (( EUID == 0 )) || die '请先切换到 root，再从 Bash 终端运行。'
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 && -r /etc/os-release ]] || die '需要 amd64 Linux。'
    # shellcheck source=/etc/os-release
    . /etc/os-release
    case "$ID:$VERSION_ID" in
        debian:13|ubuntu:22.04) ;;
        *) die '当前支持 Debian 13 和 Ubuntu 22.04。' ;;
    esac
    local -a required=(curl openssl sha256sum python3 ss ip flock systemctl pgrep getent id useradd userdel groupdel)
    [[ "$protocol" != vless ]] || required+=(unzip)
    local -a missing=()
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done
    (( ${#missing[@]} == 0 )) || die "缺少命令：${missing[*]}。请先补齐依赖。"
    [[ -s "$CA_BUNDLE" ]] || die '缺少系统 CA 证书，请先安装 ca-certificates。'
    [[ -d /run/systemd/system ]] || die '未检测到运行中的 systemd。'
    systemctl show --property=Version >/dev/null || die '无法连接 systemd。'
}

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

check_conflicts() {
    local units pattern process path core
    local -a known
    if [[ "$protocol" == vless ]]; then
        core=xray
        pattern='^(xray|x-ui|3x-ui|vps-proxy-vless)([.@-][^[:space:]]*)?\.service([[:space:]]|$)'
        process='xray(-.*)?'
        known=(/etc/xray /usr/local/etc/xray /usr/bin/xray /usr/local/bin/xray)
    else
        core=hysteria
        pattern='^(hysteria|hy2|vps-proxy-hy2)([.@-][^[:space:]]*)?\.service([[:space:]]|$)'
        process='(hysteria|hy2)(-.*)?'
        known=(/etc/hysteria /usr/local/etc/hysteria /usr/bin/hysteria /usr/local/bin/hysteria)
    fi
    for path in "$target" "$unit_file" "${known[@]}"; do
        if path_exists "$path"; then die "发现现有服务文件 $path。"; fi
    done
    if command -v "$core" >/dev/null; then
        die 'PATH 中已有同类服务端程序。'
    fi
    if getent passwd "$account" >/dev/null || getent group "$account" >/dev/null; then
        die "服务账号或组 $account 已存在。"
    fi
    units=$(systemctl list-unit-files --type=service --no-legend --no-pager) || die '无法检查 systemd 单元文件。'
    if grep -Eq "$pattern" <<< "$units"; then die '发现现有同类 systemd 单元。'; fi
    units=$(systemctl list-units --type=service --all --plain --no-legend --no-pager) || die '无法检查已加载的 systemd 单元。'
    if grep -Eq "$pattern" <<< "$units"; then die '发现已加载的同类 systemd 服务。'; fi
    if pgrep -x "$process" >/dev/null; then die '发现运行中的同类进程。'; fi
}

port_sockets() {
    local -a family=()
    [[ -z ${1:-} ]] || family=(-6)
    if [[ "$transport" == TCP ]]; then
        ss "${family[@]}" -H -ltnpe "sport = :$listen_port"
    else
        ss "${family[@]}" -H -uanpe "sport = :$listen_port"
    fi
}

check_port() {
    local sockets
    sockets=$(port_sockets) || die "无法检查 $listen_port/$transport。"
    if [[ -n "$sockets" ]]; then die "本机 $listen_port/$transport 已被占用。"; fi
}

check_certificate() {
    local cert=$1 key=$2 name cert_public key_public san
    local -a match
    cert_public=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) || die '无法读取证书 PEM。'
    key_public=$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null) || die '需要可读且未加密的 PEM 私钥。'
    [[ -n "$key_public" && "$cert_public" == "$key_public" ]] || die '证书和私钥不匹配。'
    for name in "${tls_name:-$host}" "${secondary:+${tls_name:-$secondary}}"; do
        [[ -n "$name" ]] || continue
        if [[ "$name" == *:* || "$name" =~ ^[0-9.]+$ ]]; then
            match=(-verify_ip "$name")
        else
            san=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null) || die '证书缺少 SAN。'
            [[ "$san" == *DNS:* ]] || die '证书缺少 DNS SAN。'
            match=(-verify_hostname "$name")
        fi
        openssl verify -CAfile "$CA_BUNDLE" -untrusted "$cert" -purpose sslserver "${match[@]}" "$cert" >/dev/null 2>&1 ||
            die "证书的有效期、CA 链或验证名 $name 未通过校验。请检查 fullchain 和证书验证名。"
    done
}

has_local_ipv6() {
    local addresses
    addresses=$(ip -6 -o addr show scope global "$@") || die '无法检查本机 IPv6。'
    [[ -n "$addresses" ]] && grep -Evq '(^|[[:space:]])(tentative|dadfailed)([[:space:]]|$)' <<< "$addresses"
}

collect_settings() {
    local first second extra default_cert='' default_key=''
    prompt '连接地址（公网 IPv4、IPv6 或域名，可在后面空格追加一个直连 IPv6）：'
    read -r first second extra <<< "$REPLY"
    [[ -n "$first" && -z "$extra" ]] || die '请输入一个连接地址，或再追加一个 IPv6。'
    host=$(normalize_host "$first") || die '连接地址无效。'
    secondary=''
    unavailable_secondary=''
    if [[ -n "$second" ]]; then
        secondary=$(normalize_host "$second") || die '附加的 IPv6 地址无效。'
        [[ "$host" != *:* && "$secondary" == *:* ]] || die '附加 IPv6 前需先填写 IPv4 或域名。'
    fi
    if [[ -n "$secondary" ]]; then
        has_local_ipv6 to "$secondary/128" || die "附加的直连 IPv6 [$secondary] 未分配给本机或尚不可用。"
    elif [[ "$host" == *:* ]]; then
        has_local_ipv6 || die '本机没有可用的 IPv6 地址。'
    fi
    prompt "$protocol_name 本机监听端口（$transport）[443]："
    listen_port=$(normalize_port "${REPLY:-443}") || die '监听端口须为 1–65535。'
    check_port
    prompt "$protocol_name 客户端连接的公网端口（$transport）[$listen_port]："
    public_port=$(normalize_port "${REPLY:-$listen_port}") || die '公网端口须为 1–65535。'
    printf '\n1. 复用现有 CA 签发证书\n2. 生成自签证书并在客户端固定指纹\n' >&3
    prompt '证书方式 [1]：'
    tls_name=''
    cert_file=''
    key_file=''
    case "${REPLY:-1}" in
        1)
            cert_mode=ca
            if [[ -f "/etc/letsencrypt/live/$host/fullchain.pem" && -f "/etc/letsencrypt/live/$host/privkey.pem" ]]; then
                default_cert="/etc/letsencrypt/live/$host/fullchain.pem"
                default_key="/etc/letsencrypt/live/$host/privkey.pem"
            fi
            prompt "fullchain.pem 绝对路径${default_cert:+ [$default_cert]}："
            cert_file=${REPLY:-$default_cert}
            prompt "私钥 PEM 绝对路径${default_key:+ [$default_key]}："
            key_file=${REPLY:-$default_key}
            [[ "$cert_file" == /* && -f "$cert_file" && "$key_file" == /* && -f "$key_file" ]] ||
                die '请填写存在的证书和私钥文件的绝对路径。'
            prompt '证书验证名（IP 连域名证书时填证书域名，留空则按各连接地址验证）：'
            if [[ -n "$REPLY" ]]; then
                tls_name=$(normalize_host "$REPLY") || die '证书验证名无效。'
            fi
            check_certificate "$cert_file" "$key_file"
            ;;
        2) cert_mode=self ;;
        *) die '无效的证书方式。' ;;
    esac
}

print_mapping() {
    printf '主连接地址 %s:%s（%s），本机监听 %s/%s\n' \
        "$(uri_host "$host")" "$public_port" "$transport" "$listen_port" "$transport" >&3
    if [[ "$host" != *:* ]]; then
        printf '使用 IPv4 NAT 时，在商家面板填一行：%s 公网端口 %s → 本机端口 %s。\n' \
            "$transport" "$public_port" "$listen_port" >&3
    fi
    if [[ -n "$secondary" ]]; then
        printf '附加 IPv6 直连 [%s]:%s（%s）。\n' "$secondary" "$listen_port" "$transport" >&3
    elif [[ -n "${unavailable_secondary:-}" ]]; then
        printf '附加 IPv6 [%s] 当前不可用，已省略对应的直连链接。\n' "$unavailable_secondary" >&3
    fi
}

stage_certificate() {
    local subject_alt_name
    if [[ "$cert_mode" == ca ]]; then
        cp -- "$cert_file" "$stage/cert.pem"
        cp -- "$key_file" "$stage/key.pem"
        check_certificate "$stage/cert.pem" "$stage/key.pem"
        return
    fi
    if [[ "$host" == *:* || "$host" =~ ^[0-9.]+$ ]]; then
        subject_alt_name="IP:$host"
    else
        subject_alt_name="DNS:$host"
    fi
    subject_alt_name+="${secondary:+,IP:$secondary}"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -sha256 -days 365 -subj '/CN=VPS Proxy' -addext "subjectAltName=$subject_alt_name" \
        -addext 'basicConstraints=critical,CA:FALSE' -addext 'keyUsage=critical,digitalSignature' \
        -addext 'extendedKeyUsage=serverAuth' -keyout "$stage/key.pem" -out "$stage/cert.pem" 2>/dev/null ||
        die '生成自签证书失败。'
}

stage_binary() {
    local url digest
    if [[ "$protocol" == vless ]]; then
        url="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-64.zip"
        digest=$XRAY_SHA256
    else
        url="https://github.com/HyNetworks/hysteria/releases/download/app/$HY2_VERSION/hysteria-linux-amd64"
        digest=$HY2_SHA256
    fi
    curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 180 --retry 2 --output "$stage/download" "$url" || die '下载官方发布资产失败。'
    printf '%s  %s\n' "$digest" "$stage/download" | sha256sum --check --status || die '官方发布资产 SHA-256 不匹配。'
    if [[ "$protocol" == vless ]]; then
        unzip -p "$stage/download" xray > "$stage/server" || die '无法从官方 ZIP 提取 Xray。'
        rm -- "$stage/download"
    else
        mv -- "$stage/download" "$stage/server"
    fi
    chmod 0755 "$stage/server"
}

write_config() {
    if [[ "$protocol" == vless ]]; then
        cat <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $listen_port,
    "protocol": "vless",
    "settings": {"decryption": "none", "users": [{"id": "$credential", "flow": "xtls-rprx-vision"}]},
    "streamSettings": {
      "network": "raw", "security": "tls",
      "tlsSettings": {"minVersion": "1.3", "certificates": [{"certificateFile": "$target/cert.pem", "keyFile": "$target/key.pem"}]}
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    else
        # JSON 是 Hysteria 支持的配置格式。IPv4 NAT 场景的本机地址可与证书 IP 不同。
        cat <<EOF
{
  "listen": ":$listen_port",
  "tls": {"cert": "$target/cert.pem", "key": "$target/key.pem", "sniGuard": "disable"},
  "auth": {"type": "password", "password": "$credential"}
}
EOF
    fi
}

write_unit() {
    local arguments
    if [[ "$protocol" == vless ]]; then
        arguments="run -config $target/config.json"
    else
        arguments="server --disable-update-check -c $target/config.json"
    fi
    cat <<EOF
[Unit]
Description=Personal VPS proxy ($protocol)
After=network.target

[Service]
Type=simple
User=$account
Group=$account
ExecStart=$target/server $arguments
Restart=on-failure
RestartSec=2s
NoNewPrivileges=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

matches_listener() {
    local sockets=$1 state=$2 pid=$3 line account_uid=''
    while IFS= read -r line; do
        [[ "$line" == "$state"[[:space:]]* ]] || continue
        if [[ "$line" == *"pid=$pid,"* ]]; then return 0; fi
        [[ "$line" != *'pid='* ]] || continue
        # 受限容器可能隐藏其他 UID 的进程详情，仍可核对专用服务账号拥有的监听。
        if [[ -z "$account_uid" ]]; then account_uid=$(id -u "$account") || return 1; fi
        if [[ "$line" =~ [[:space:]]uid:"$account_uid"([[:space:]]|$) ]]; then return 0; fi
    done <<< "$sockets"
    return 1
}

is_listening() {
    local pid sockets state=LISTEN
    systemctl is-active --quiet "$unit" || return 1
    pid=$(systemctl show --property=MainPID --value "$unit") || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    sockets=$(port_sockets) || return 1
    [[ "$transport" == TCP ]] || state=UNCONN
    matches_listener "$sockets" "$state" "$pid" || return 1
    if [[ "$host" == *:* || -n "$secondary" ]]; then
        sockets=$(port_sockets 6) || return 1
        matches_listener "$sockets" "$state" "$pid" || return 1
    fi
}

wait_for_listener() {
    local attempt consecutive=0
    for ((attempt=0; attempt<20; attempt++)); do
        if is_listening; then
            consecutive=$((consecutive + 1))
            if (( consecutive == 3 )); then return 0; fi
        else
            consecutive=0
        fi
        sleep 0.25
    done
    die "$unit 未稳定监听 $listen_port/$transport。请查看 journalctl -u $unit -n 30。"
}

certificate_pin() {
    local fingerprint
    fingerprint=$(openssl x509 -in "$1" -noout -sha256 -fingerprint) || return 1
    fingerprint=${fingerprint#*=}
    fingerprint=${fingerprint//:/}
    [[ "$fingerprint" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf '%s\n' "${fingerprint,,}"
}

collect_links() {
    local primary_name=$tls_name secondary_name=$tls_name
    if [[ "$cert_mode" == ca ]]; then
        # 域名与证书名一致时可由客户端自动推导，IP 证书显式传验证名。
        if [[ -z "$tls_name" && ( "$host" == *:* || "$host" =~ ^[0-9.]+$ ) ]]; then primary_name=$host; fi
        if [[ -z "$tls_name" && -n "$secondary" ]]; then secondary_name=$secondary; fi
    fi
    if [[ "$cert_mode" == self ]]; then
        has_self_signed=1
    fi
    main_links+=("$(render_link "$protocol" "$host" "$public_port" "$credential" "$primary_name" "$pin")")
    if [[ -n "$secondary" ]]; then
        ipv6_links+=("$(render_link "$protocol" "$secondary" "$listen_port" "$credential" "$secondary_name" "$pin")")
    fi
}

print_links() {
    if (( has_self_signed )); then
        printf '\n自签节点请在 v2rayN 选择 Xray 核心，保留证书指纹。\n' >&3
    fi
    printf '\nv2rayN 主连接导入链接（%s 条）\n' "${#main_links[@]}" >&3
    printf '%s\n' "${main_links[@]}" >&3
    if (( ${#ipv6_links[@]} )); then
        printf '\n额外的 IPv6 直连导入链接\n' >&3
        printf '%s\n' "${ipv6_links[@]}" >&3
    fi
    printf '\n在 VPS 外选中该节点并使用全局代理模式，经 v2rayN 的本地 SOCKS 端口测试（按实际端口替换 10808）：\n' >&3
    printf '%s\n' 'curl --fail --max-time 20 --noproxy "" --proxy socks5h://127.0.0.1:10808 https://api.ipify.org' >&3
    printf '将返回地址与 VPS 上直连同一网址所得的出口地址比对。仅有 IPv6 出口时，两端均改用 https://api6.ipify.org。\n' >&3
}

check_service_unit() {
    local fragment drop_ins
    fragment=$(systemctl show --property=FragmentPath --value "$unit") || die '无法读取服务单元。'
    [[ "$fragment" == "$unit_file" ]] || die "服务 $unit 来自其他单元文件。"
    drop_ins=$(systemctl show --property=DropInPaths --value "$unit") || die '无法检查服务覆盖配置。'
    [[ -z "$drop_ins" ]] || die "服务 $unit 包含额外的 systemd 覆盖配置。"
}

load_installation() {
    local path
    local -a state
    pin=''
    [[ -d "$target" && ! -L "$target" && -f "$unit_file" && ! -L "$unit_file" ]] || die '安装目录或服务单元不完整。'
    for path in state config.json cert.pem key.pem server; do
        [[ -f "$target/$path" && ! -L "$target/$path" ]] || die '已有安装文件不完整。'
    done
    cmp -s "$unit_file" <(write_unit) || die '现有服务单元与脚本管理的单元不匹配。'
    check_service_unit
    mapfile -t state < "$target/state"
    [[ ${#state[@]} == 7 && ${state[0]} == vps-proxy-installer-1 ]] || die '无法识别安装状态。'
    host=$(normalize_host "${state[1]}") || die '已保存的连接地址无效。'
    secondary=''
    unavailable_secondary=''
    if [[ -n ${state[2]} ]]; then
        secondary=$(normalize_host "${state[2]}") || die '已保存的 IPv6 无效。'
        [[ "$secondary" == *:* ]] || die '已保存的 IPv6 无效。'
        if ! has_local_ipv6 to "$secondary/128"; then
            unavailable_secondary=$secondary
            secondary=''
        fi
    fi
    listen_port=$(normalize_port "${state[3]}") || die '已保存的监听端口无效。'
    public_port=$(normalize_port "${state[4]}") || die '已保存的公网端口无效。'
    cert_mode=${state[5]}
    tls_name=''
    if [[ -n ${state[6]} ]]; then tls_name=$(normalize_host "${state[6]}") || die '已保存的证书验证名无效。'; fi
    case "$cert_mode" in
        ca) check_certificate "$target/cert.pem" "$target/key.pem" ;;
        self)
            openssl x509 -in "$target/cert.pem" -noout -checkend 0 >/dev/null || die '自签证书已过期或无法读取。'
            pin=$(certificate_pin "$target/cert.pem") || die '无法计算自签证书指纹。'
            ;;
        *) die '已保存的证书方式无效。' ;;
    esac
    credential=$(python3 - "$protocol" "$target/config.json" 2>/dev/null <<'PY'
import json
import re
import sys

with open(sys.argv[2], encoding='utf-8') as config:
    data = json.load(config)
if sys.argv[1] == 'vless':
    value = data['inbounds'][0]['settings']['users'][0]['id']
    pattern = r'[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}'
else:
    value = data['auth']['password']
    pattern = r'[a-f0-9]{64}'
if not re.fullmatch(pattern, value):
    sys.exit(1)
print(value)
PY
    ) || die '无法从本机配置读取原凭据。'
    is_listening || die "现有服务未监听 $listen_port/$transport。请检查 systemctl status $unit。"
}

cleanup() {
    local status=$? preserve=0 account_record account_comment
    trap - EXIT
    trap '' INT TERM HUP
    set +e
    if (( status != 0 )); then
        if (( start_attempted )); then
            systemctl stop "$unit" >/dev/null || preserve=1
        fi
        if (( enable_attempted )); then
            systemctl disable "$unit" >/dev/null || preserve=1
        fi
        if (( preserve )); then
            printf '无法完全停止或禁用本次创建的服务。已保留 %s 及 %s 供排查。\n' "$unit_file" "$target" >&2
        else
            if [[ -n "$temp_unit" && "$temp_unit" -ef "$unit_file" ]]; then
                rm -- "$unit_file" || preserve=1
                systemctl daemon-reload >/dev/null || preserve=1
            fi
            if [[ -n "$stage_inode" && $(stat -c '%d:%i' -- "$target" 2>/dev/null) == "$stage_inode" ]]; then
                rm -f -- "$target/"{server,config.json,cert.pem,key.pem,state} || preserve=1
                rmdir -- "$target" || preserve=1
            fi
            if [[ -n "$account_marker" ]] && account_record=$(getent passwd "$account"); then
                IFS=: read -r _ _ _ _ account_comment _ _ <<< "$account_record"
                if [[ "$account_comment" == "$account_marker" ]]; then
                    userdel "$account" || preserve=1
                    if getent group "$account" >/dev/null; then groupdel "$account" || preserve=1; fi
                fi
            fi
            if (( preserve )); then printf '本次安装有残留，请检查上方错误。\n' >&2; fi
        fi
    fi
    if [[ -n "$temp_unit" ]]; then rm -f -- "$temp_unit"; fi
    if [[ -n "$stage" && -d "$stage" ]]; then rm -rf -- "$stage"; fi
    exit "$status"
}

install_service() {
    local stage='' stage_inode='' temp_unit='' account_marker='' start_attempted=0 enable_attempted=0
    # EXIT trap 在当前子 shell 内运行，安装临时状态在陷阱执行时仍可读。
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    stage=$(mktemp -d "/opt/.vps-proxy-$protocol.XXXXXX")
    stage_inode=$(stat -c '%d:%i' -- "$stage")
    stage_binary
    stage_certificate
    if [[ "$cert_mode" == self ]]; then certificate_pin "$stage/cert.pem" >/dev/null || die '无法计算自签证书指纹。'; fi
    if [[ "$protocol" == vless ]]; then
        credential=$(python3 -c 'import uuid; print(uuid.uuid4())')
    else
        credential=$(openssl rand -hex 32)
    fi
    write_config > "$stage/config.json"
    printf '%s\n' vps-proxy-installer-1 "$host" "$secondary" "$listen_port" "$public_port" "$cert_mode" "$tls_name" > "$stage/state"

    # 下载后再查一次端口及同类服务，避免覆盖安装等待期间出现的配置。
    check_conflicts
    check_port
    # 标记由本次安装创建的账号。即使 useradd 刚完成便收到信号，回退也可识别其来源。
    account_marker="VPS Proxy Installer ${stage##*/}"
    useradd --system --user-group --no-create-home --comment "$account_marker" --home-dir "$target" --shell /usr/sbin/nologin "$account"
    chgrp -- "$account" "$stage" "$stage/"{config.json,cert.pem,key.pem}
    chmod 0750 "$stage"
    chmod 0640 "$stage/"{config.json,cert.pem,key.pem}
    mv -T --no-clobber -- "$stage" "$target"
    [[ ! -e "$stage" ]] || die "已有目录 $target。"

    if [[ "$protocol" == vless ]]; then
        "$target/server" run -test -config "$target/config.json" >/dev/null || die 'Xray 配置检查失败。'
    fi
    temp_unit=$(mktemp "/etc/systemd/system/.vps-proxy-$protocol.XXXXXX")
    write_unit > "$temp_unit"
    chmod 0644 "$temp_unit"
    ln -T -- "$temp_unit" "$unit_file" || die "无法创建 $unit_file。"
    systemctl daemon-reload
    check_service_unit
    start_attempted=1
    systemctl start "$unit"
    wait_for_listener
    enable_attempted=1
    systemctl enable "$unit" >/dev/null

    trap - EXIT INT TERM HUP
    rm -- "$temp_unit" || printf '未能清理安装临时文件 %s。\n' "$temp_unit" >&2
}

confirm_installation() {
    prompt '确认安装 [y/N]：'
    case "$REPLY" in
        y|Y|yes|YES) ;;
        *) printf '已取消。\n' >&3; return 1 ;;
    esac
}

lock_installation() {
    # /run 下的锁在重启时清理；保留同一个 inode，避免并发执行时锁失效。
    [[ ! -L /run/vps-proxy-installer.lock ]] || die '安装锁路径异常。'
    exec 8>>/run/vps-proxy-installer.lock
    flock --nonblock 8 || die '另一个安装正在执行。'
}

deploy_selection() {
    local selected field has_self_signed=0
    local -a pending=() main_links=() ipv6_links=()
    local -a fields=(host secondary listen_port public_port cert_mode tls_name cert_file key_file)
    local -A settings=()

    for selected in "${selected_protocols[@]}"; do
        select_protocol "$selected"
        check_environment
        printf '\n配置 %s\n' "$protocol_name" >&3
        if path_exists "$target"; then
            load_installation
            printf '检测到本脚本已有安装，使用原端口和凭据。\n' >&3
        else
            check_conflicts
            collect_settings
            pending+=("$selected")
            # 两个协议的设置先保存在内存，收集完毕后统一确认。
            for field in "${fields[@]}"; do
                settings["$selected:$field"]=${!field}
            done
            printf '\n待安装 %s %s，证书方式：%s。\n' "$protocol_name" "$version" "$cert_mode" >&3
        fi
        print_mapping
    done

    if (( ${#pending[@]} )); then
        confirm_installation || return 0
        lock_installation
        for selected in "${pending[@]}"; do
            select_protocol "$selected"
            for field in "${fields[@]}"; do
                printf -v "$field" '%s' "${settings[$selected:$field]}"
            done
            check_conflicts
            check_port
            ( install_service )
            printf '\n%s 已安装。\n' "$protocol_name" >&3
        done
    fi

    for selected in "${selected_protocols[@]}"; do
        select_protocol "$selected"
        load_installation
        printf '\n%s\n' "$protocol_name" >&3
        print_mapping
        collect_links
    done
    printf '\n所选服务已启动并监听本机端口。客户端连通性待外部验证。\n' >&3
    print_links
}

main() {
    set -Eeuo pipefail
    export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
    umask 077
    local -a selected_protocols=()
    { exec 3<>/dev/tty; } 2>/dev/null || die '请在交互式 Bash 终端运行。'
    menu
    deploy_selection
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

# VPS 代理一键部署

在带 systemd 的 Debian 13 LXC 或 Ubuntu 22.04 amd64 VPS 上，用 root 的 Bash 运行。下载地址固定到已验证的脚本提交。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jianmomo/vps-proxy-installer/800e749246f668565d6f770df5ae61b5ae8e49fd/install.sh)
```

- `1` 安装 VLESS + TCP + XTLS Vision + TLS，使用 [Xray v26.11.9](https://github.com/XTLS/Xray-core/releases/tag/v26.11.9)。
- `2` 安装 Hysteria 2 + QUIC + TLS，使用 [官方 Hysteria 2 v2.13.0](https://github.com/HyNetworks/hysteria/releases/tag/app/v2.13.0)。
- `0` 退出。

VPS 需能访问 GitHub Release。脚本从官方 Release 下载 amd64 文件并核验 SHA-256。运行前准备 Bash、`curl`、`ca-certificates`、`openssl`、`iproute2`、`util-linux`、`procps` 和 `python3`。VLESS 还需要 `unzip`。缺少命令时，按终端提示补齐后重跑。

## 地址和端口

连接地址填客户端实际访问的公网 IP 或直连域名。监听端口填 VPS 内的端口，公网端口填客户端连接的端口。直连且没有端口映射时，两者填同一个值。

| 选项 | VPS 监听 | 客户端连接 | 服务商 NAT 面板 |
| --- | --- | --- | --- |
| Hysteria 2 | 443/UDP | 公网地址的 40050/UDP | 公网 40050/UDP → VPS 443/UDP |
| VLESS | 81/TCP | 公网地址的 44432/TCP | 公网 44432/TCP → VPS 81/TCP |

双栈可在连接地址一栏填写 `IPv4或域名 IPv6`，以空格分隔。脚本另导出一条使用监听端口的 IPv6 直连链接。只填一个 IPv6 地址时，链接使用所填公网端口。链接里的 IPv6 字面地址会加方括号。

## TLS 与导入

优先选已有证书，提供客户端信任的 PEM 完整证书链和匹配的私钥。若用 IP 直连、证书签给域名，填写证书覆盖的域名作为 TLS 验证名。脚本复制证书和私钥到服务目录。证书续期后，需要同步更新副本并重启相应服务。

选择自签时，使用 [v2rayN 7.25.6](https://github.com/2dust/v2rayN/releases/tag/7.25.6)，将客户端 Xray 内核更新至 v26.11.9，并把该节点的核心类型选为 **Xray**。VLESS 链接使用 `pcs`，Hysteria 2 链接使用 `pcs` 和 `pinSHA256`。两者固定的是叶证书的 SHA-256 指纹。自签证书更换后需重新导入链接。 [v2rayN 的 Xray TLS 配置](https://github.com/2dust/v2rayN/blob/7.25.6/v2rayN/ServiceLib/Services/CoreConfig/V2ray/V2rayOutboundService.cs#L292-L338)

安装前核对摘要并确认。完整导入链接仅显示在当前终端，从 v2rayN 的剪贴板导入即可。发现已有同类服务或端口冲突时退出。再次选择已由本脚本安装的协议，只检查服务并重显原链接，沿用原凭据和配置。每个服务使用同名的专用系统用户和组（省略 `.service`），失败时回退本次安装。NAT 映射由你在商家面板设置。

| 协议 | 安装目录 | systemd 服务 |
| --- | --- | --- |
| VLESS | `/opt/vps-proxy-vless` | `vps-proxy-vless.service` |
| Hysteria 2 | `/opt/vps-proxy-hy2` | `vps-proxy-hy2.service` |

## 从 VPS 外验证

安装后显示的服务和监听检查只验证 VPS 本地状态。在 v2rayN 中选中导入的节点，使用全局路由，然后从 VPS 以外的电脑运行下方命令。`10808` 换成 v2rayN 实际的本地 SOCKS 端口。

```bash
curl -fsS --max-time 20 --noproxy '' --proxy socks5h://127.0.0.1:10808 https://api.ipify.org
```

在 VPS 上直连运行 `curl -fsS --noproxy '*' https://api.ipify.org` 获取出口 IP。若代理请求成功并返回 VPS 的出口 IP，即验证了公网入口、协议握手、认证和转发。NAT VPS 的公网入口与出口 IP 可能不同。若 VPS 只有 IPv6 出口，两条命令都改用 `https://api6.ipify.org`。Windows 可在命令提示符用 `curl.exe` 执行，把 `''` 换为 `""`。 [IP 查询接口](https://www.ipify.org/#api)

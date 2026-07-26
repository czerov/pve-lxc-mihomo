# PVE LXC Mihomo 旁路由一键安装教程

适用场景：amd64 或 ARM64 PVE LXC 容器部署 Mihomo / NexusBox 旁路由，解决核心不兼容 `amd64-v3`、架构模板不匹配、国内网络下载困难、NexusBox 热重载、provider 节点测速和 NAT 防火墙自启等问题。

## 典型问题

如果 LXC 核心启动失败、NexusBox 提示 `core.sock` 不存在，常见原因是核心文件和 CPU 指令集不匹配。第四阶段正常时应能看到：

```text
ip_forward = 1
-A POSTROUTING -o eth0 -j MASQUERADE
```

如果出现下面的报错，说明 CPU 不支持 `amd64-v3`，脚本会自动换成 compatible 核心：

```text
This program can only be run on AMD64 processors with v3 microarchitecture support.
```

## 一键脚本功能

主要脚本：

- `pve-install-cn.sh`：在 PVE 宿主机运行，中文交互完成第 1-4 阶段。
- `install-cn.sh`：在现有 LXC 内运行，安装或修复 Mihomo / NexusBox。

它会自动做这些检测和处理：

- 自动检测 CPU 架构。
- PVE 宿主机自动匹配 amd64 / ARM64 Debian LXC 模板，并在创建 CT 时指定正确架构。
- x86_64 下自动判断是否支持 `amd64-v3`。
- 支持 `amd64-v3` 时安装 `mihomo-linux-amd64-v3`。
- 不支持 `amd64-v3` 时安装 `mihomo-linux-amd64-compatible`。
- ARM64 下自动安装 `mihomo-linux-arm64` 和 ARM64 NexusBox 修补版。
- 检测是否存在 `/opt/nexusbox/nexusbox`。
- 如果存在 NexusBox：自动替换 `/opt/mihomo/mihomo` 核心并重启 NexusBox。
- 自动安装修补版 NexusBox，兼容当前 Mihomo 热重载 API。
- 代理页自动读取 provider 节点测速历史，显示延迟或“超时”。
- 新建 LXC 默认从官方脚本安装 NexusBox，并安装 Zashboard。
- 可显式选择纯 Mihomo systemd 服务。
- 自动测试 Mihomo 配置。
- 默认启用 KDocs `System` TUN、DNS 53 和 Fake-IP 198.18.0.0/16；TUN 启动失败自动完整重启并回退 `gVisor`。
- 自动配置 rc.local MASQUERADE 自启。
- 自动配置 IPv4/IPv6 转发和 IPv6 RA。
- 自动安装缺失的 `iptables` 等依赖。
- 国内网络下载：先试 GitHub 原地址，失败后试 GitHub 加速地址。
- 所有覆盖前都会备份原文件，不批量删除文件。

## PVE 宿主机中文交互安装

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
```

## 现有 LXC 容器内安装 / 修复

自动判断已有环境：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install-cn.sh)
```

只修复 NexusBox：

```bash
MODE=nexusbox bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install-cn.sh)
```

只安装纯 Mihomo：

```bash
MODE=standalone bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install-cn.sh)
```

如果以后要指定版本：

```bash
VERSION=v1.19.28 bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install-cn.sh)
```

## 安装完成后检查

执行：

```bash
cat /proc/sys/net/ipv4/ip_forward
cat /proc/sys/net/ipv6/conf/all/forwarding
iptables -t nat -S POSTROUTING
ip link show Meta
ss -lntup | grep -E '(:53|:7890|:9090|:18080)'
```

期望看到：

```text
1
-A POSTROUTING -o eth0 -j MASQUERADE
```

NexusBox 场景还应看到：

```text
/opt/nexusbox/nexusbox
LXC_IP:18080 页面正常
LXC_IP:7890 代理端口正常
LXC_IP:9090 控制端口正常
```

## 主路由第五阶段配置

默认采用 KDocs 高性能模式，终端设备保持原主路由，只修改 DNS：

```text
网关：保持原主路由
DNS：LXC 容器 IP，例如 192.168.1.9
```

主路由添加：

```text
目的网络：198.18.0.0
子网掩码：255.255.0.0
下一跳/网关：LXC 容器 IP，例如 192.168.1.9
```

并关闭“允许 ICMP 重定向”。KDocs 模式会自动启用 Mihomo TUN，NexusBox 中不需要再打开 TProxy。手动切换 TUN 栈后应停止再启动核心，不要直接热重载 TUN 配置。

### 爱快源 IP 白名单全流量模式

如果只希望指定设备使用 Mihomo，并且不想逐台设置网关和 DNS，可在爱快 `端口分流` 中创建 `MihomoHTTPS专用`：

```text
分流方式：下一跳网关
下一跳：LXC IP
协议：TCP+UDP
优先级：5
源地址：允许使用 Mihomo 的设备 IP，关闭反向匹配
目的地址：反向排除 10.0.0.0/8、172.16.0.0/12、192.168.0.0/16、127.0.0.0/8
源端口：留空
目的端口：留空
```

设备只需固定 DHCP 地址，单设备网关和 DNS 字段留空。爱快 DHCP 服务端应下发公网 IPv4 DNS，使白名单设备的 DNS 请求也能通过该规则进入 Mihomo。以后只需维护 `MihomoHTTPS专用` 的源地址列表。

该方案会让白名单设备的全部 IPv4 TCP/UDP 经过 LXC，不再具有 KDocs 模式“国内流量物理绕过 LXC”的容灾优势。严格白名单模式还应停用全局 `198.18.0.0/16` 和 Telegram 补充静态路由，避免非白名单设备从其他路径进入 Mihomo。完整步骤见 [IKUAI-WHITELIST.md](IKUAI-WHITELIST.md)。

该模式默认只覆盖 Fake-IP。爱快用户可将以下 Telegram IPv4 网段的下一跳设置为 LXC IP，使固定 DC IP 进入 Mihomo：

```text
91.108.56.0/22
91.108.4.0/22
91.108.8.0/22
91.108.16.0/22
91.108.12.0/22
149.154.160.0/20
91.105.192.0/23
91.108.20.0/22
185.76.151.0/24
```

Telegram IPv6 网段：

```text
2001:b28:f23d::/48
2001:b28:f23f::/48
2001:67c:4e8::/48
2001:b28:f23c::/48
2a0a:f280::/32
```

IPv4 下一跳统一填写 LXC IPv4；IPv6 下一跳填写安装报告自动检测出的当前 LXC `fe80::` 地址。两者的出口接口都选择爱快 LAN 接口。IPv6 链路本地下一跳不能跨设备复用。

需要完整网关模式时执行：

```bash
ROUTING_MODE=gateway bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
```

然后把终端设备网关和 DNS 都设置为 LXC IP。

## 常见问题

### iPhone TikTok 一直加载

最新默认配置会叠加 `TikTok-iOS` 域名集和独立代理 DNS，同时保留 TikTok 的 UDP/QUIC。实测部分 iOS TikTok 版本在 UDP 被拒绝后不会回退 TCP，而是持续重试并显示“无网络连接”。已有 NexusBox 可执行：

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/update-tiktok-routing.sh | bash
```

更新脚本也会移除旧版的 TikTok UDP 拒绝规则。更新后在 TikTok 分组选择确认支持 UDP 且真实连接正常的新加坡、日本或美国节点，再完全关闭 iPhone TikTok 后重新打开。仅测速正常并不代表节点可用；如果日志出现 `503 Service Unavailable`，请更换到另一家订阅的节点。

如果日志已显示 `api16-core.tiktokv.com` 或 `api22-core.tiktokv.com` 正确走 TikTok 节点，但 App 仍提示“无网络连接”，先在同一手机上用本地 VPN 客户端和同一条节点做对照。若本地 VPN 可以正常使用，说明节点和 SIM 不是主要问题，应排查 KDocs 模式未接管的固定 IP、IPv6、加密 DNS 或其他 UDP 流量，并为该终端改用 [爱快源 IP 白名单全流量模式](IKUAI-WHITELIST.md) 或完整网关模式。若本地 VPN 同样失败，再检查设备地区；TikTok 会结合 SIM 卡地区、出口 IP 和系统设置判断位置，开启飞行模式或关闭蜂窝数据不一定会隐藏已安装 SIM/eSIM 的归属地区。

### core.sock 不存在

一般是核心没启动。先检查：

```bash
/opt/mihomo/mihomo -v
/opt/mihomo/mihomo -t -d /opt/config
ls -la /opt/nexusbox/var
```

如果出现：

```text
This program can only be run on AMD64 processors with v3 microarchitecture support.
```

说明 CPU 不支持 amd64-v3，运行本脚本会自动换 compatible 核心。

### apt 下载总是走坏代理

检测到明确的 LXC 代理时，APT 会优先使用代理；代理失败后才回退直连。没有配置代理时会明确关闭 APT 代理：

```bash
apt-get -o Acquire::http::Proxy=false -o Acquire::https::Proxy=false ...
```

如果你的网络必须走代理，可以在运行前设置：

```bash
export http_proxy=http://你的代理:端口
export https_proxy=http://你的代理:端口
```

### 第四阶段 NAT 没生效

重新执行：

```bash
/etc/rc.local
iptables -t nat -S POSTROUTING
```

如果没有规则，确认 `iptables` 是否安装：

```bash
command -v iptables
```

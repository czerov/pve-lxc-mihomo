# PVE LXC Mihomo 旁路由一键安装教程

适用场景：PVE LXC 容器部署 Mihomo / NexusBox 旁路由，解决核心不兼容 `amd64-v3`、国内网络下载困难、NexusBox 热重载、provider 节点测速和 NAT 防火墙自启等问题。

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
- x86_64 下自动判断是否支持 `amd64-v3`。
- 支持 `amd64-v3` 时安装 `mihomo-linux-amd64-v3`。
- 不支持 `amd64-v3` 时安装 `mihomo-linux-amd64-compatible`。
- 检测是否存在 `/opt/nexusbox/nexusbox`。
- 如果存在 NexusBox：自动替换 `/opt/mihomo/mihomo` 核心并重启 NexusBox。
- 自动安装修补版 NexusBox，兼容当前 Mihomo 热重载 API。
- 代理页自动读取 provider 节点测速历史，显示延迟或“超时”。
- 新建 LXC 默认从官方脚本安装 NexusBox，并安装 Zashboard。
- 可显式选择纯 Mihomo systemd 服务。
- 自动测试 Mihomo 配置。
- 默认启用 KDocs TUN、DNS 53 和 Fake-IP 198.18.0.0/16。
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

并关闭“允许 ICMP 重定向”。KDocs 模式会自动启用 Mihomo TUN，NexusBox 中不需要再打开 TProxy。

该模式只覆盖 Fake-IP。Telegram 固定 DC IP、真实 IP、IPv6 和部分 UDP 可能绕过 LXC。

需要完整网关模式时执行：

```bash
ROUTING_MODE=gateway bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
```

然后把终端设备网关和 DNS 都设置为 LXC IP。

## 常见问题

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

脚本会用：

```bash
apt-get -o Acquire::http::Proxy=false -o Acquire::https::Proxy=false ...
```

绕过坏代理。如果你的网络必须走代理，可以在运行前设置：

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

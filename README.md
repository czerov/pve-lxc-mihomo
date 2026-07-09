# PVE LXC Mihomo 旁路由一键安装

一键部署 / 修复 PVE LXC 里的 Mihomo / NexusBox 旁路由。

特点：

- 自动检测 CPU 是否支持 `amd64-v3`
- 支持则安装 `amd64-v3` 核心
- 不支持则自动安装 `compatible` 核心
- 自动修复 NexusBox 的 `/opt/mihomo/mihomo`
- 自动配置 `/etc/rc.local` NAT 自启
- 自动开启 IPv4 转发
- 自动安装 `iptables` 等依赖
- PVE 宿主机自动检测桥接网卡、网关和内网网段
- 自动选择同网段可用 LXC IP
- 覆盖前自动备份，不批量删除文件
- 适配国内网络下载
- 附带 Debian LXC 代理开关脚本，方便容器内临时配置 APT 代理

## 1-4 阶段全自动

在 PVE 宿主机执行。

国外网络：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

国内网络：

```bash
bash <(curl -fsSL https://gh.llkk.cc/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

常用参数示例：

默认会自动检测 PVE 当前内网，不需要写死 IP：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

也可以手动指定：

```bash
CTID=109 CT_IP_CIDR=192.168.1.9/24 CT_GW=192.168.1.1 CT_BRIDGE=vmbr0 bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

自动完成：

- 第 1 阶段：下载 Debian LXC 模板并创建 LXC
- 第 2 阶段：配置 LXC 特权、嵌套、TUN
- 第 3 阶段：进入 LXC 安装 / 修复 Mihomo 或 NexusBox 核心
- 第 4 阶段：配置 LXC 内 NAT、`ip_forward`、`/etc/rc.local`

## 已有 LXC 自动安装 / 修复

如果 LXC 已经创建好，在 PVE 宿主机执行：

```bash
USE_EXISTING=1 CTID=109 bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

国内网络：

```bash
USE_EXISTING=1 CTID=109 bash <(curl -fsSL https://gh.llkk.cc/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

脚本会自动读取 `/etc/pve/lxc/109.conf` 里的 `net0`，识别 LXC IP、网桥、网关。如果容器是 DHCP，会启动容器后从容器内部自动读取当前 IP。

## LXC 代理助手

这个脚本来自 `czerov/pve-proxy` 的思路，已改成不写死局域网 IP。适合在 Debian LXC 容器里临时开启 / 关闭 APT 代理。

菜单模式：

```bash
source <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/proxy.sh)
```

自动探测并开启：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/proxy.sh) on
```

手动指定代理：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/proxy.sh) on 192.168.1.100:7897
```

关闭代理：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/proxy.sh) off
```

## 仅容器内安装 / 修复

如果 LXC 已经建好，只想在容器内安装或修复核心，用下面命令。

### 国外网络

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install.sh)
```

### 国内网络

```bash
bash <(curl -fsSL https://gh.llkk.cc/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install.sh)
```

备用：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install.sh)
```

## 指定模式

自动判断 NexusBox / 纯 Mihomo：

```bash
MODE=auto bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install.sh)
```

只修复 NexusBox 核心：

```bash
MODE=nexusbox bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install.sh)
```

只安装纯 Mihomo 旁路由：

```bash
MODE=standalone bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install.sh)
```

## 指定版本

默认版本：

```text
v1.19.28
```

指定版本：

```bash
VERSION=v1.19.28 bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install.sh)
```

## 国内下载核心加速

脚本会自动尝试 GitHub 原始地址和几个加速地址。

也可以手动指定：

```bash
GH_PROXY=https://gh.llkk.cc bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install.sh)
```

## 安装后主路由配置

在主路由添加静态路由：

```text
目的网络：198.18.0.0
子网掩码：255.255.0.0
下一跳/网关：LXC 容器 IP，例如 192.168.1.9
```

终端设备 DNS 填 LXC 容器 IP，例如：

```text
192.168.1.9
```

## 详细教程

见 [GUIDE.md](GUIDE.md)。

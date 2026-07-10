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
- PVE 自动安装时可选集成 LXC 代理，APT 和核心下载都会走代理

## 1-4 阶段全自动

在 PVE 宿主机执行。

注意：`pve-install.sh` 不是在 LXC 容器里执行的。如果终端提示符像 `root@msn`、`root@debian`，并且报 `pct not found`，说明你进的是容器；请切到 PVE 宿主机 root shell，或者改用下面的“仅容器内安装 / 修复”命令。

默认会弹出交互选择：

- 纯 Mihomo 旁路由：无 NexusBox UI，无 `18080`
- 自动模式：已有 NexusBox 就修复核心，否则装纯 Mihomo
- 修复已有 NexusBox 核心
- 从零安装 NexusBox UI 后修复核心，默认使用 Ladavian/NexusBox 官方安装脚本，并自动尝试 CDN / GitHub 加速源
- LXC 代理：关闭、自动探测、手动输入

如果不想交互，可以加 `INTERACTIVE=0` 并用环境变量指定。

国外网络：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

国内网络：

```bash
bash <(curl -fsSL https://gh.llkk.cc/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

如果 `raw.githubusercontent.com` 或 GitHub 代理不可用，使用 jsDelivr CDN：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/czerov/pve-lxc-mihomo@main/pve-install-cn.sh)
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

如果 PVE 官方模板下载慢，可以指定模板 URL：

```bash
TEMPLATE_URL=https://mirrors.tuna.tsinghua.edu.cn/proxmox/images/system/debian-12-standard_12.12-1_amd64.tar.zst \
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/czerov/pve-lxc-mihomo@main/pve-install-cn.sh)
```

默认新建 LXC 会优先使用本地模板：

```text
debian-13-standard_13.1-2_amd64.tar.zst
```

如果本地没有这个模板，默认 `TEMPLATE_MIRROR=auto` 会自动测速并选择最快可用源：

```text
清华 TUNA
中科大 USTC
南京大学 NJU
Proxmox 官方源
```

下载失败会自动换下一个源。也可以手动关闭镜像测速下载，改回 PVE 自带 `pveam download`：

```bash
TEMPLATE_MIRROR=pveam bash <(curl -fsSL https://cdn.jsdelivr.net/gh/czerov/pve-lxc-mihomo@main/pve-install-cn.sh)
```

如果要指定其他本地模板，可以设置：

```bash
CT_TEMPLATE_NAME=debian-12-standard_12.12-1_amd64.tar.zst bash <(curl -fsSL https://cdn.jsdelivr.net/gh/czerov/pve-lxc-mihomo@main/pve-install-cn.sh)
```

脚本会自动选择 LXC 根磁盘存储：优先 `local-lvm`，不存在时使用 `local`。也可以手动指定：

```bash
CT_ROOTFS_STORAGE=local bash <(curl -fsSL https://cdn.jsdelivr.net/gh/czerov/pve-lxc-mihomo@main/pve-install-cn.sh)
```

安装结束前脚本会复查运行状态：进程、systemd 服务、监听端口、`ip_forward` 和 NAT 规则都通过后才打印成功。新建 LXC 默认是纯 Mihomo 模式，不安装 NexusBox，所以没有 `18080` 页面；选择 NexusBox 安装模式后才会开放 `18080` 页面。

如果容器内下载慢，可以让自动安装流程先配置 LXC 代理，再安装 Mihomo / NexusBox：

```bash
LXC_PROXY=auto bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

默认会自动导入仓库里的公开版 `config.yaml`：保留 AI、Google、Telegram、Netflix、Apple、Microsoft、PT、游戏、Speedtest 等规则分组，不包含私人订阅地址。

如果要自动导入自己的规则配置，可以传入 `CONFIG_URL`。脚本会下载配置、备份旧配置、补齐 NexusBox 必需的控制端口配置、测试配置并重启服务：

```bash
CONFIG_URL=https://example.com/config.yaml \
LXC_INSTALL_MODE=nexusbox-install \
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/czerov/pve-lxc-mihomo@main/pve-install-cn.sh)
```

不要把包含私人订阅、节点或密钥的 `config.yaml` 直接提交到公开仓库。

如果不想导入默认配置，可以关闭：

```bash
CONFIG_URL=off bash <(curl -fsSL https://cdn.jsdelivr.net/gh/czerov/pve-lxc-mihomo@main/pve-install-cn.sh)
```

`auto` 只会在容器内探测到在线代理时启用。也可以强制指定代理：

```bash
LXC_PROXY=on LXC_PROXY_ADDR=192.168.1.100:7897 bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

关闭或清理容器内代理：

```bash
LXC_PROXY=disable USE_EXISTING=1 CTID=109 bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
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

自动安装脚本 `pve-install.sh` 已经可以通过 `LXC_PROXY=auto` 或 `LXC_PROXY=on` 调用它；下面这些命令适合单独在容器里使用。

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

自动判断 NexusBox / 纯 Mihomo。纯 Mihomo 模式没有 `18080` Web 页面，只提供代理、DNS 和控制 API：

```bash
MODE=auto bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install.sh)
```

从零安装 NexusBox UI：

```bash
MODE=nexusbox-install bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install.sh)
```

默认安装脚本地址是：

```text
https://raw.githubusercontent.com/Ladavian/NexusBox/main/install.sh
```

下载失败时会自动尝试 `cdn.jsdelivr.net`、`fastly.jsdelivr.net`、`testingcf.jsdelivr.net` 和 GitHub 加速源。也可以手动指定：

```bash
MODE=nexusbox-install NEXUSBOX_INSTALL_URL=https://cdn.jsdelivr.net/gh/Ladavian/NexusBox@main/install.sh bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install.sh)
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

# PVE LXC Mihomo / NexusBox 旁路由一键安装

在 Proxmox VE 宿主机上一键完成 Debian 13 LXC 创建、Mihomo / NexusBox 安装、默认规则导入和透明代理配置。安装菜单、检测过程和完成报告均使用中文。

## 当前版本功能

- 自动检测 PVE 网桥、网关、内网网段、存储和可用 LXC IP
- 默认使用 Debian 13 模板，自动测速清华、中科大、南大和 Proxmox 下载源
- CTID 被占用时自动选择下一个空闲 ID
- 自动检测 `amd64-v3`，老 CPU / J1900 自动使用 `amd64-compatible`
- 自动获取 Mihomo 最新版本，失败时使用稳定兜底版本
- 可选择纯 Mihomo、自动判断、修复 NexusBox、从零安装 NexusBox
- NexusBox 修补版兼容当前 Mihomo 热重载 API，解决 `Body invalid`
- NexusBox 代理页支持 provider 节点测速，正常显示延迟或“超时”
- 默认导入公开安全的 MSM 风格规则，保留 AI、Google、Telegram、Netflix、Apple、Microsoft、PT、游戏和 Speedtest 分组
- 自动配置 DNS 53 转发、TCP 透明代理、NAT、IPv4 转发和 `/etc/rc.local` 自启
- 国内下载自动尝试 `gh-proxy.com`、`gh.llkk.cc`、GitHub Raw 和 jsDelivr
- 安装前自动备份被覆盖文件，不包含私人订阅、节点、密码或密钥

## 中文交互一键安装

在 **PVE 宿主机的 root shell** 执行：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
```

备用入口：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/czerov/pve-lxc-mihomo@main/pve-install-cn.sh)
```

注意：`pve-install.sh` 不是在 LXC 容器里执行的。如果终端提示符像 `root@msn`、`root@debian`，并且报 `pct not found`，说明你进的是容器；请切到 PVE 宿主机 root shell，或者改用下面的“仅容器内安装 / 修复”命令。

默认会弹出交互选择：

- 纯 Mihomo 旁路由：无 NexusBox UI，无 `18080`
- 自动模式：已有 NexusBox 就修复核心，否则装纯 Mihomo
- 修复已有 NexusBox 核心
- 从零安装 NexusBox UI 后修复核心，默认使用 Ladavian/NexusBox 官方安装脚本，并自动尝试 CDN / GitHub 加速源
- NexusBox 模式会替换为仓库内修补版 NexusBox 二进制，修复当前 mihomo 热重载 `Body invalid`，并让代理页正确读取 provider 节点延迟、显示测速结果或“超时”
- LXC 代理：关闭、自动探测、手动输入

如果不想交互，可以加 `INTERACTIVE=0` 并用环境变量指定。

常用参数示例：

默认会自动检测 PVE 当前内网，不需要写死 IP：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
```

默认从 `CTID=109` 开始创建；如果 109 已存在，会自动选择下一个空闲 CTID。手动传入 `CTID=xxx` 时默认严格使用该 ID，若希望从指定 ID 往后找空闲 ID，可以加 `AUTO_CTID=1`。

也可以手动指定：

```bash
CTID=109 CT_IP_CIDR=192.168.1.9/24 CT_GW=192.168.1.1 CT_BRIDGE=vmbr0 bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
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

安装结束前脚本会复查运行状态：进程、systemd 服务、监听端口、`ip_forward`、NAT 规则和 mihomo 配置热重载都通过后才打印成功。新建 LXC 默认是纯 Mihomo 模式，不安装 NexusBox，所以没有 `18080` 页面；选择 NexusBox 安装模式后才会开放 `18080` 页面。

如果导入的配置里 `dns.listen` 不是标准 `53` 端口，例如公开默认配置使用 `0.0.0.0:6666`，脚本会自动在 LXC 内持久化 DNS 转发，把客户端访问的 `53/tcp` 和 `53/udp` 转到实际 DNS 端口，并在健康检查里验证这条规则。

无代理也可以尝试一键安装。国内网络建议从 `pve-install-cn.sh` 启动，它会默认启用 `PREFER_CN_ACCEL=1`，优先使用 jsDelivr、`gh-proxy.com` 等国内可用源，raw GitHub 只作为最后兜底。Mihomo 核心、NexusBox 和 `geoip.dat` / `geosite.dat` / `country.mmdb` 都带多源回退；GEO 文件还会检查下载大小，避免把错误页面当成数据库。若所有加速源都不可用，再使用 `LXC_PROXY=auto` 或手动指定代理。

`pve-install-cn.sh` 入口会优先拉取 GitHub raw / GitHub 加速源的新脚本，CDN 只作为兜底，避免 `cdn.jsdelivr.net @main` 缓存旧版脚本导致菜单或逻辑不是最新。

如果容器内下载慢，可以让自动安装流程先配置 LXC 代理，再安装 Mihomo / NexusBox：

```bash
LXC_PROXY=auto bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
```

默认会自动导入仓库里的公开版 `config.yaml`：保留 AI、Google、Telegram、Netflix、Apple、Microsoft、PT、游戏、Speedtest 等规则分组，不包含私人订阅地址。NexusBox 模式下脚本会把订阅模式设为 `merge`（融合），后续添加多个机场订阅时会逐条同步到 `proxy-providers`，只把订阅作为节点来源，规则和分组仍使用这份默认配置；不要切到 `switch`（切换）模式，否则会使用机场自带的完整配置。

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

`auto` 会把 PVE 当前 SSH/FinalShell 来源 IP、PVE 邻居表、网关、DNS 和常见 Clash/Mihomo 端口传入 LXC 逐个探测；只有探测到在线代理时才启用。也可以强制指定代理：

```bash
LXC_PROXY=on LXC_PROXY_ADDR=192.168.1.100:7897 bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
```

关闭或清理容器内代理：

```bash
LXC_PROXY=disable USE_EXISTING=1 CTID=109 bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
```

自动完成：

- 第 1 阶段：下载 Debian LXC 模板并创建 LXC
- 第 2 阶段：配置 LXC 特权、嵌套、TUN
- 第 3 阶段：进入 LXC 安装 / 修复 Mihomo 或 NexusBox 核心
- 第 4 阶段：配置 LXC 内 NAT、`ip_forward`、`/etc/rc.local`

## 已有 LXC 自动安装 / 修复

如果 LXC 已经创建好，在 PVE 宿主机执行：

```bash
USE_EXISTING=1 CTID=109 bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
```

脚本会自动读取 `/etc/pve/lxc/109.conf` 里的 `net0`，识别 LXC IP、网桥、网关。如果容器是 DHCP，会启动容器后从容器内部自动读取当前 IP。

## LXC 代理助手

这个脚本来自 `czerov/pve-proxy` 的思路，已改成不写死局域网 IP。适合在 Debian LXC 容器里临时开启 / 关闭 APT 代理。

自动安装脚本 `pve-install.sh` 已经可以通过 `LXC_PROXY=auto` 或 `LXC_PROXY=on` 调用它；下面这些命令适合单独在容器里使用。

菜单模式：

```bash
source <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/proxy.sh)
```

自动探测并开启：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/proxy.sh) on
```

手动指定代理：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/proxy.sh) on 192.168.1.100:7897
```

关闭代理：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/proxy.sh) off
```

## 仅容器内安装 / 修复

如果 LXC 已经建好，只想在容器内安装或修复核心，用下面命令。

### 中文安装入口

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install-cn.sh)
```

备用：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/czerov/pve-lxc-mihomo@main/install-cn.sh)
```

## 指定模式

自动判断 NexusBox / 纯 Mihomo。纯 Mihomo 模式没有 `18080` Web 页面，只提供代理、DNS 和控制 API：

```bash
MODE=auto bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install-cn.sh)
```

从零安装 NexusBox UI：

```bash
MODE=nexusbox-install bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install-cn.sh)
```

默认安装脚本地址是：

```text
https://raw.githubusercontent.com/Ladavian/NexusBox/main/install.sh
```

下载失败时会自动尝试 `cdn.jsdelivr.net`、`fastly.jsdelivr.net`、`testingcf.jsdelivr.net` 和 GitHub 加速源。也可以手动指定：

```bash
MODE=nexusbox-install NEXUSBOX_INSTALL_URL=https://cdn.jsdelivr.net/gh/Ladavian/NexusBox@main/install.sh bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install-cn.sh)
```

只修复 NexusBox 核心：

```bash
MODE=nexusbox bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install-cn.sh)
```

只安装纯 Mihomo 旁路由：

```bash
MODE=standalone bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install-cn.sh)
```

## 指定版本

默认会自动解析 MetaCubeX Mihomo 最新 release，并按 CPU 自动选择 `amd64-v3` / `amd64-compatible` / `arm64` 核心。如果 GitHub API 和加速源都不可用，会退回到脚本内置的稳定兜底版本。

默认版本策略：

```text
latest，兜底 v1.19.28
```

如果要固定版本：

```bash
VERSION=v1.19.28 bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install-cn.sh)
```

## 国内下载核心加速

脚本会自动尝试 GitHub 原始地址和几个加速地址。

也可以手动指定：

```bash
GH_PROXY=https://gh.llkk.cc bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install-cn.sh)
```

## 安装后主路由配置

### 方式 A（推荐）

把终端设备或主路由的网关和 DNS 都指向 LXC 容器 IP，例如 `192.168.1.9`。脚本会在 LXC 内配置 TCP 透明代理、DNS 转发和 NAT。

该方式能够处理 Telegram 固定 DC IP，以及没有经过 Fake-IP DNS 查询的 App 连接。Telegram、TikTok、YouTube 等移动 App 应使用方式 A。NexusBox 中保持 TUN、TProxy 关闭即可使用脚本配置的透明代理链路。

### 方式 B（兼容性有限，不推荐用于移动 App）

保留原网关，只把终端设备 DNS 填 LXC 容器 IP，并在主路由添加 Fake-IP 静态路由：

```text
目的网络：28.0.0.0
子网掩码：255.0.0.0
下一跳/网关：LXC 容器 IP，例如 192.168.1.9
```

终端设备 DNS：

```text
192.168.1.9
```

方式 B 只会把 `28.0.0.0/8` Fake-IP 流量送到 LXC。Telegram 固定 DC IP、应用缓存的真实 IP、IPv6 和部分 UDP 流量不会命中该静态路由，可能出现网页正常但 Telegram 一直“连接中”的情况。

## 详细教程

见 [GUIDE.md](GUIDE.md)。

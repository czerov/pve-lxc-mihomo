# PVE 阶段 1-4 自动化说明

这个文件说明 `pve-install.sh` 自动做了教程前 4 个阶段中的哪些事。

## 运行位置

`pve-install.sh` 必须在 PVE 宿主机执行，不是在 LXC 容器里执行。

默认会交互询问安装模式和 LXC 代理模式。如果要完全无人值守，设置：

```bash
INTERACTIVE=0 LXC_INSTALL_MODE=standalone LXC_PROXY=auto bash <(curl -fsSL ...)
```

## 一键命令

国外网络：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

国内网络：

```bash
bash <(curl -fsSL https://gh.llkk.cc/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

CDN 入口：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/czerov/pve-lxc-mihomo@main/pve-install-cn.sh)
```

常用自定义参数：

默认会自动检测 PVE 当前内网：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

脚本会自动检测：

- PVE 当前桥接网卡，例如 `vmbr0`
- PVE 当前内网 IP，例如 `192.168.1.100/24`
- 默认网关，例如 `192.168.1.1`
- 同网段可用 LXC IP，优先尝试 `.9`、`.6`、`.8`、`.10` 等常用地址；都不可用时继续扫描当前网段

也可以手动指定：

```bash
CTID=109 \
CT_HOSTNAME=mihomo-router \
CT_IP_CIDR=192.168.1.9/24 \
CT_GW=192.168.1.1 \
CT_BRIDGE=vmbr0 \
CT_ROOTFS_STORAGE=local-lvm \
CT_TEMPLATE_STORAGE=local \
bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

已有 LXC 容器则使用：

```bash
USE_EXISTING=1 CTID=109 bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

如果 LXC 内下载 GitHub / apt 较慢，可以把代理助手融入自动流程：

```bash
LXC_PROXY=auto bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

`LXC_PROXY=auto` 会把 PVE 当前 SSH/FinalShell 来源 IP、PVE 邻居表、网关、DNS 和常见 Clash/Mihomo 端口传入容器探测，只有探测到在线代理才启用；没有探测到就继续直连安装。

手动指定代理：

```bash
LXC_PROXY=on \
LXC_PROXY_ADDR=192.168.1.100:7897 \
bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

常用参数：

```text
LXC_PROXY=off       默认，不配置代理
LXC_PROXY=auto      自动探测在线代理，探测不到则跳过
LXC_PROXY=on        开启代理，可配合 LXC_PROXY_ADDR
LXC_PROXY=disable   清理容器内代理配置
LXC_PROXY_ADDR=IP:端口
LXC_PROXY_PORT=7897
LXC_PROXY_COMMON_PORTS="7897 7890 7891 7892 7893 7895 7896 7899 1080 10808 10809 20170 20171"
CONFIG_URL=默认使用仓库公开 config.yaml；可设置为自定义 URL；设置 off 可关闭导入
```

已有容器模式会：

- 读取 `/etc/pve/lxc/<CTID>.conf`。
- 自动解析 `net0` 里的 `ip=`、`gw=`、`bridge=`。
- 如果 `ip=dhcp`，会启动容器并通过 `pct exec` 自动读取容器当前 IPv4。
- 跳过创建容器阶段。
- 继续配置 TUN、嵌套权限，并进入容器执行安装。
- 如果设置了 `CONFIG_URL`，会在容器内下载自定义 `config.yaml`，备份旧配置，补齐 NexusBox 控制端口字段，测试配置后重启服务。

## 第 1 阶段：创建 LXC

脚本会：

- 检查当前是否是 PVE 宿主机。
- 检查 `pct`、`pveam`、`curl`。
- 检查 `CTID` 是否已存在，已存在则停止，避免覆盖。
- 自动检测 PVE 内网桥接、网关、CIDR。
- 自动选择同网段可用 LXC IP。
- 自动优先查找本地 `debian-13-standard_13.1-2_amd64.tar.zst` 模板。
- 如果指定模板不存在，则查找 Debian 13 amd64 模板，再回退 Debian 12 amd64 模板。
- 本地没有指定模板时，默认 `TEMPLATE_MIRROR=auto` 自动测速清华 TUNA、中科大 USTC、南京大学 NJU、Proxmox 官方源，并选择最快可用源。
- 镜像下载失败会自动换下一个；全部失败再回退到 `pveam download`。
- 本地没有模板时自动用 `pveam download` 下载。
- 用 `pct create` 创建 Debian LXC。

如果使用 `USE_EXISTING=1`，脚本会跳过创建步骤，改为检测已有 LXC 网络信息。

默认参数：

```text
CTID=109
CT_HOSTNAME=mihomo-router
CT_IP_CIDR=自动检测
CT_GW=自动检测
CT_BRIDGE=自动检测
CT_ROOTFS_STORAGE=自动检测，优先 local-lvm，不存在则使用 local
CT_TEMPLATE_STORAGE=local
CT_CORES=1
CT_MEMORY=512
CT_SWAP=0
CT_DISK_SIZE=8
CT_TEMPLATE_NAME=debian-13-standard_13.1-2_amd64.tar.zst
TEMPLATE_MIRROR=auto
TEMPLATE_URL=空，优先自动测速镜像并下载指定模板；镜像不可用时使用 pveam 下载 Debian 13 模板；如果 PVE 源没有 Debian 13，再回退到 Debian 12
```

如果 `download.proxmox.com` 很慢，可以设置 `TEMPLATE_URL` 指定模板下载地址。

## 第 2 阶段：配置 LXC 权限 / TUN

脚本会：

- 设置特权容器：`--unprivileged 0`
- 开启 `nesting=1,keyctl=1`
- 备份 `/etc/pve/lxc/<CTID>.conf`
- 写入 TUN 权限：

```text
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

## 第 3 阶段：容器内安装 / 修复核心

脚本会：

- 启动 LXC。
- 如果设置了 `LXC_PROXY=auto/on/disable`，先在容器内配置或清理 APT / shell 代理。
- 把 `install.sh` 推送到容器 `/root/mihomo-router-install.sh`。
- 在容器内执行安装脚本。
- 如果容器内代理已启用，安装脚本的 `curl` 下载也会继承 `http_proxy` / `https_proxy`。

容器内脚本会：

- 自动检测 CPU 架构。
- 自动检测是否支持 `amd64-v3`。
- 支持则安装 `mihomo-linux-amd64-v3`。
- 不支持则安装 `mihomo-linux-amd64-compatible`。
- 如果检测到 `/opt/nexusbox/nexusbox`，则修复 NexusBox 的 `/opt/mihomo/mihomo`。
- 如果没有 NexusBox，则安装纯 Mihomo systemd 服务。
- 纯 Mihomo 模式不会安装 NexusBox UI，因此不会开放 `18080`。
- 如果要从零安装 NexusBox UI，使用 `LXC_INSTALL_MODE=nexusbox-install`。默认会使用 Ladavian/NexusBox 官方安装脚本，并自动尝试 CDN / GitHub 加速源；需要时也可以自定义 `NEXUSBOX_INSTALL_URL`。
- 脚本会验证进程、服务、端口、`ip_forward` 和 NAT 规则；验证失败会直接报错，不打印成功。

## 第 4 阶段：LXC 内防火墙 / NAT 自启

容器内脚本会：

- 自动检测出口网卡，例如 `eth0`。
- 安装缺失的 `iptables`。
- 开启 IPv4 转发：

```bash
echo 1 >/proc/sys/net/ipv4/ip_forward
```

- 备份并写入 `/etc/rc.local`：

```bash
#!/bin/sh -e
echo 1 >/proc/sys/net/ipv4/ip_forward
iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
exit 0
```

- 立即执行 `/etc/rc.local`。

## 第 5 阶段

第 5 阶段仍需要根据主路由型号处理。脚本结束时会提示：

```text
route: 198.18.0.0/16 -> LXC_IP
client DNS: LXC_IP
```

如果主路由是 OpenWrt/iStoreOS/ImmortalWrt，后续可以继续加 `router-openwrt.sh` 做自动配置。

# PVE 阶段 1-4 自动化说明

这个文件说明 `pve-install.sh` 自动做了教程前 4 个阶段中的哪些事。

## 运行位置

`pve-install.sh` 必须在 PVE 宿主机执行，不是在 LXC 容器里执行。

## 一键命令

国外网络：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
```

国内网络：

```bash
bash <(curl -fsSL https://gh.llkk.cc/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install.sh)
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
- 同网段可用 LXC IP，优先尝试 `.9`，被占用则尝试 `.6`、`.8`、`.10` 等

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

已有容器模式会：

- 读取 `/etc/pve/lxc/<CTID>.conf`。
- 自动解析 `net0` 里的 `ip=`、`gw=`、`bridge=`。
- 如果 `ip=dhcp`，会启动容器并通过 `pct exec` 自动读取容器当前 IPv4。
- 跳过创建容器阶段。
- 继续配置 TUN、嵌套权限，并进入容器执行安装。

## 第 1 阶段：创建 LXC

脚本会：

- 检查当前是否是 PVE 宿主机。
- 检查 `pct`、`pveam`、`curl`。
- 检查 `CTID` 是否已存在，已存在则停止，避免覆盖。
- 自动检测 PVE 内网桥接、网关、CIDR。
- 自动选择同网段可用 LXC IP。
- 自动查找本地 Debian 12 LXC 模板。
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
CT_ROOTFS_STORAGE=local-lvm
CT_TEMPLATE_STORAGE=local
CT_CORES=1
CT_MEMORY=512
CT_SWAP=0
CT_DISK_SIZE=8
```

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
- 把 `install.sh` 推送到容器 `/root/mihomo-router-install.sh`。
- 在容器内执行安装脚本。

容器内脚本会：

- 自动检测 CPU 架构。
- 自动检测是否支持 `amd64-v3`。
- 支持则安装 `mihomo-linux-amd64-v3`。
- 不支持则安装 `mihomo-linux-amd64-compatible`。
- 如果检测到 `/opt/nexusbox/nexusbox`，则修复 NexusBox 的 `/opt/mihomo/mihomo`。
- 如果没有 NexusBox，则安装纯 Mihomo systemd 服务。

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

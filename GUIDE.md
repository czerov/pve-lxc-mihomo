# PVE LXC Mihomo 旁路由一键安装教程

适用场景：PVE LXC 容器部署 Mihomo / NexusBox 旁路由，解决核心不兼容 `amd64-v3`、国内网络下载困难、第四阶段 NAT 防火墙自启等问题。

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

脚本文件：`mihomo-router-onekey.sh`

它会自动做这些检测和处理：

- 自动检测 CPU 架构。
- x86_64 下自动判断是否支持 `amd64-v3`。
- 支持 `amd64-v3` 时安装 `mihomo-linux-amd64-v3`。
- 不支持 `amd64-v3` 时安装 `mihomo-linux-amd64-compatible`。
- 检测是否存在 `/opt/nexusbox/nexusbox`。
- 如果存在 NexusBox：自动替换 `/opt/mihomo/mihomo` 核心并重启 NexusBox。
- 如果不存在 NexusBox：自动安装纯 Mihomo systemd 服务。
- 自动测试 Mihomo 配置。
- 自动配置 `/etc/rc.local` NAT 自启。
- 自动开启 `/proc/sys/net/ipv4/ip_forward`。
- 自动安装缺失的 `iptables` 等依赖。
- 国内网络下载：先试 GitHub 原地址，失败后试 GitHub 加速地址。
- 所有覆盖前都会备份原文件，不批量删除文件。

## 使用方法

把脚本上传到 LXC 容器，或在 FinalShell 文件区拖进去，然后执行：

```bash
chmod +x mihomo-router-onekey.sh
./mihomo-router-onekey.sh
```

如果只想修复 NexusBox 核心：

```bash
MODE=nexusbox ./mihomo-router-onekey.sh
```

如果只想装纯 Mihomo 旁路由：

```bash
MODE=standalone ./mihomo-router-onekey.sh
```

如果 GitHub 下载慢，可以指定你自己的加速前缀：

```bash
GH_PROXY=https://gh.llkk.cc ./mihomo-router-onekey.sh
```

如果以后要指定版本：

```bash
VERSION=v1.19.28 ./mihomo-router-onekey.sh
```

## 安装完成后检查

执行：

```bash
cat /proc/sys/net/ipv4/ip_forward
iptables -t nat -S POSTROUTING
ss -lntup | grep -E '(:7890|:7898|:9090|:1053|:18080)'
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

在主路由后台添加静态路由：

```text
目的网络：198.18.0.0
子网掩码：255.255.0.0
下一跳/网关：LXC 容器 IP，例如 192.168.1.9
```

并关闭“允许 ICMP 重定向”一类选项。

终端设备如果要走旁路由：

```text
网关：保持原主路由
DNS：LXC 容器 IP，例如 192.168.1.9
```

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

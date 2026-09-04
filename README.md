# PVE LXC Mihomo / NexusBox

在 amd64 或 ARM64 Proxmox VE 上自动创建或复用 Debian LXC，并安装 Mihomo、NexusBox 和 Zashboard。默认使用中文交互、KDocs 旁路由模式和公开规则配置。

## 主要功能

- 自动检测 PVE 网桥、网关、存储、空闲 CTID 和 LXC IP。
- 自动识别 PVE 的 amd64 / ARM64 架构，只创建同架构 Debian LXC。
- x86 自动选择 `amd64-v3` 或兼容版核心；ARM64 自动选择 ARM64 Mihomo 与 NexusBox。
- 安装 Mihomo、NexusBox 修补版、Zashboard、TUN、DNS、NAT 和开机自启。
- 默认导入 AI、Google、YouTube、Telegram、Netflix、TikTok、PT 和游戏等分流规则。
- 修改配置前自动备份，安装和更新后校验配置；失败时尽量自动恢复。
- 不在仓库中保存私人订阅、节点、密码或密钥。

## 一键安装

在 **PVE 宿主机 root shell** 执行：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
```

按菜单选择安装方式。直接回车使用推荐设置：

- 从 `CTID=109` 开始寻找空闲 ID。
- 创建 Debian 13 LXC。
- 安装完整 NexusBox。
- 使用 KDocs 高性能旁路由模式。

安装完成后，脚本会显示 LXC IP 和访问地址：

```text
NexusBox: http://LXC_IP:18080
代理端口: LXC_IP:7890
控制接口: http://LXC_IP:9090
DNS:      LXC_IP:53
```

> `pve-install-cn.sh` 必须在 PVE 宿主机运行。出现 `pct: command not found` 说明当前终端位于 LXC 容器内。

### AMD64 / ARM64

两种架构使用同一条安装命令。脚本会显示类似 `PVE 架构检测：aarch64 -> arm64`，并在创建 CT 时显式指定正确架构。

- amd64：优先使用本地或 Proxmox 镜像中的 Debian 13/12 amd64 模板。
- ARM64：优先使用本地或 `pveam` 中的同架构模板；没有时从清华 LXC 镜像和 [Linux Containers 官方镜像](https://images.linuxcontainers.org/)解析最新 Debian 13 ARM64 根文件系统。
- ARM64 备用模板必须通过 SHA-256 与压缩包完整性检查，用户指定的模板文件名若明确属于其他架构会被拒绝。

ARM 版 PVE 通常来自社区移植。脚本要求宿主机已经具备可正常工作的 `pct`、`pveam` 和 LXC；本项目不会安装或修复 PVE 本身。

## 已有 LXC

在 PVE 宿主机安装或修复现有容器：

```bash
USE_EXISTING=1 CTID=109 bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
```

只在容器内部安装或修复：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/install-cn.sh)
```

## 路由模式

### KDocs 模式（默认）

终端设备保持原网关，只把 DNS 设置为 LXC IP；主路由添加一条静态路由：

```text
目的网络：198.18.0.0/16
下一跳：LXC IP
```

该模式通过 Fake-IP 和 TUN 接管流量，默认优先使用吞吐更高的 `System` 栈；若容器内无法创建 TUN，安装脚本会完整重启并自动回退 `gVisor`。NexusBox 中无需再开启 TProxy。Telegram 等固定 IP 网段的配置见 [GUIDE.md](GUIDE.md)。

切换 TUN 协议栈后应停止再启动核心，不能只做配置热重载；否则旧 TUN 设备未释放时可能出现 `device or resource busy`。

### 爱快源 IP 白名单模式（可选）

爱快可以用一条名为 `MihomoHTTPS专用` 的端口分流规则，把源地址列表内设备的全部 IPv4 TCP/UDP 转发到 LXC。设备继续自动获取原网关和 DHCP 默认 DNS，不需要单独填写 LXC DNS；加入源地址列表即使用 Mihomo，移除后即恢复普通网络。

该规则的源端口和目的端口都必须留空，不能只填写 `443`。详细配置、严格白名单要求和 IPv6 限制见 [爱快源 IP 白名单全流量模式](IKUAI-WHITELIST.md)。

### 完整网关模式

```bash
ROUTING_MODE=gateway bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
```

安装完成后，将终端设备的网关和 DNS 都设置为 LXC IP。

## 常用参数

| 参数 | 作用 |
| --- | --- |
| `CTID=109` | 指定容器 ID |
| `USE_EXISTING=1` | 使用已有 LXC |
| `CT_TEMPLATE_NAME=...` | 指定同架构本地模板名 |
| `TEMPLATE_URL=...` | 指定同架构模板下载地址 |
| `TEMPLATE_MIRROR=pveam` | 只使用 PVE 模板目录；ARM64 不再使用备用镜像 |
| `LXC_IMAGE_MIRROR=...` | 指定 Linux Containers 镜像站根地址 |
| `ROUTING_MODE=kdocs` | 使用 KDocs 模式 |
| `ROUTING_MODE=gateway` | 使用完整网关模式 |
| `KDOCS_TUN_STACK=system` | KDocs 默认高性能 TUN；失败自动回退 `gvisor` |
| `KDOCS_TUN_STACK=gvisor` | 强制使用兼容 TUN 栈 |
| `LXC_PROXY=auto` | 自动探测安装时可用的代理 |
| `CONFIG_URL=...` | 导入自定义 Mihomo 配置 |
| `CONFIG_URL=off` | 不导入仓库默认配置 |
| `INTERACTIVE=0` | 关闭交互菜单 |

示例：

```bash
CTID=109 LXC_PROXY=auto bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/pve-install-cn.sh)
```

## 一键更新分流

在 PVE 宿主机执行：

```bash
pct exec 109 -- bash -c 'set -o pipefail; curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/update-direct-node-filter.sh | bash'
```

该脚本会：

- 排除名称含“直连/direct”的自动测速节点。
- 将区域测速调整为每 5 分钟执行，降低大量订阅节点的探测压力。
- 新增“稳定优选”：仅使用香港、美国和台湾节点，并按此顺序自动故障接管。
- 让 Google、YouTube 使用排除专线/住宅/HY2 的跨地区自动测速；人工智能、Telegram 和默认代理继续使用“稳定优选”。
- 将 Chrome Web Store 和扩展更新流量固定到美国节点。
- 自动清理历史版本可能遗留在 `proxy-providers` 后的重复 Chrome/Google 规则。
- 校验并热重载配置，失败时恢复备份。
- 幂等更新，可重复执行而不会重复添加规则。

## 已有容器更新高性能 TUN

只把现有配置更新为 `System` TUN，并保留 NexusBox 中的订阅、节点和规则：

```bash
pct exec <CTID> -- bash -c 'set -o pipefail; curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/update-system-tun.sh | bash'
```

脚本会备份当前 YAML、修复重复监听端口、完整重启核心并验证 TUN；若 `System` 无法启动，会自动回退 `gVisor`。在 LXC 容器内部执行时，去掉前面的 `pct exec <CTID> -- bash -c` 即可。

## 其他维护脚本

启用三个订阅的两级自动优选，并修复 X 一直加载、韩国节点误匹配和 GHCR/容器镜像下载缓慢：

```bash
pct exec 109 -- bash -c 'set -o pipefail; curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/update-routing-performance.sh | bash'
```

该脚本会新增“自动优选”：各地区组每 5 分钟从全部融合订阅中选出最快节点，顶层每 2 分钟只比较六个地区优胜节点，避免高频重复测试全部节点。“节点选择”“稳定优选”和“漏网之鱼”会优先使用自动优选，同时保留手动切换。脚本还会让 X 使用 `api.x.com` 做目标站可用性测速、修复短代码 `KR` 误匹配，并为 `ghcr.io` 与 `pkg-containers.githubusercontent.com` 建立独立镜像下载组。配置校验或热重载失败时自动恢复。

更新 X、Instagram、YouTube、Google 高速分流：

```bash
pct exec 109 -- bash -c 'set -o pipefail; curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/update-social-speed.sh | bash'
```

该脚本会增加“香港高速”和“社交媒体”自动测速组；“社交媒体”使用 `api.x.com` 检查目标站可用性，香港高速组排除名称含专线、住宅、直连、HY2 或 Hysteria 的节点，并为 X、Instagram/Meta 写入专用域名规则。执行前会备份配置，配置校验或热重载失败时自动恢复。

仅更新 NexusBox 修补版：

```bash
pct exec 109 -- bash -c 'curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/update-nexusbox-patch.sh | bash'
```

更新 TikTok iOS 分流：

```bash
pct exec 109 -- bash -c 'curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/update-tiktok-routing.sh | bash'
```

## 检查运行状态

```bash
pct exec 109 -- bash -c '/opt/mihomo/mihomo -t -d /opt/config'
pct exec 109 -- bash -c "ss -lntup | grep -E '(:53|:7890|:9090|:18080)'"
```

## 注意事项

- NexusBox 添加订阅时使用“融合/merge”模式，不要使用“切换/switch”模式覆盖项目规则。
- 不要将包含私人订阅地址、节点、密码或密钥的 `config.yaml` 提交到公开仓库。
- 更新脚本默认保留带时间戳的配置或二进制备份。
- Chrome Web Store 走美国节点；Codex/OpenAI 走“人工智能 → 稳定优选”（香港优先，美国、台湾依次备用）。

## 文档

- [详细安装与主路由配置](GUIDE.md)
- [爱快源 IP 白名单全流量模式](IKUAI-WHITELIST.md)
- [PVE 安装阶段说明](PVE-STAGE-1-4.md)
- [NexusBox 修补版说明](NEXUSBOX-PATCH.md)

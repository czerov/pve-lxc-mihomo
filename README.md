# PVE LXC Mihomo / NexusBox

在 Proxmox VE 上自动创建或复用 Debian LXC，并安装 Mihomo、NexusBox 和 Zashboard。默认使用中文交互、KDocs 旁路由模式和公开规则配置。

## 主要功能

- 自动检测 PVE 网桥、网关、存储、空闲 CTID 和 LXC IP。
- 自动选择 Debian 模板下载源，并适配 `amd64-v3`、兼容版 AMD64 和 ARM64 核心。
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

该模式通过 Fake-IP 和 TUN 接管流量，NexusBox 中无需再开启 TProxy。Telegram 等固定 IP 网段的配置见 [GUIDE.md](GUIDE.md)。

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
| `ROUTING_MODE=kdocs` | 使用 KDocs 模式 |
| `ROUTING_MODE=gateway` | 使用完整网关模式 |
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
- 让 Google、YouTube、人工智能、Telegram 和默认代理使用“稳定优选”。
- 将 Chrome Web Store 和扩展更新流量固定到美国节点。
- 自动清理历史版本可能遗留在 `proxy-providers` 后的重复 Chrome/Google 规则。
- 校验并热重载配置，失败时恢复备份。
- 幂等更新，可重复执行而不会重复添加规则。

## 其他维护脚本

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
- [PVE 安装阶段说明](PVE-STAGE-1-4.md)
- [NexusBox 修补版说明](NEXUSBOX-PATCH.md)

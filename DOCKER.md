# Docker 部署

Docker 版本同时支持 `linux/amd64` 和 `linux/arm64`，包含修补版 NexusBox、Mihomo、Zashboard、GEO 数据和项目默认规则。配置、订阅和运行缓存保存在宿主机的 `docker-data/config`。

## 普通代理模式

该模式使用 Docker 桥接网络并关闭 TUN，不修改宿主机路由，适合把它作为 HTTP/SOCKS 代理和 NexusBox 管理面板使用。

```bash
cp .env.docker.example .env
docker compose up -d --build
```

默认入口：

| 服务 | 地址 |
| --- | --- |
| NexusBox | `http://DOCKER_HOST:18080` |
| HTTP 代理 | `DOCKER_HOST:7890` |
| SOCKS5 代理 | `DOCKER_HOST:7891` |
| Mihomo 控制接口 | `http://DOCKER_HOST:9090` |
| DNS | `DOCKER_HOST:1053`（TCP/UDP） |

首次启动前应修改 `.env` 中的 `NEXUSBOX_PASSWORD`。这些环境变量只用于初始化新的 `nexusbox.json`，不会覆盖已经持久化的账号和订阅。

桥接模式默认把代理、控制接口和 NexusBox 端口监听在 Docker 宿主机的所有地址，便于局域网设备使用。不要把这些端口直接暴露到公网；应使用宿主机防火墙限制为可信局域网。

## macvlan 旁路由模式

旁路由模式让容器直接取得一个局域网地址，网络行为最接近本项目的 LXC 版本。先修改 `.env` 中的以下项目，确保 `LAN_IP` 未被其他设备占用：

```dotenv
LAN_INTERFACE=eth0
LAN_SUBNET=192.168.5.0/24
LAN_GATEWAY=192.168.5.1
LAN_IP=192.168.5.6
```

启动：

```bash
docker compose -f docker-compose.router.yml up -d --build
```

该模式启用 TUN，并授予容器 `NET_ADMIN`、`NET_RAW`、`NET_BIND_SERVICE` 和 `/dev/net/tun`。NexusBox 地址为 `http://LAN_IP:18080`，代理端口为 `LAN_IP:7890`，DNS 为 `LAN_IP:53`。

macvlan 默认允许其他局域网设备访问容器，但 Docker 宿主机本身不能直接访问。需要从宿主机访问时，应额外创建 macvlan shim 接口，或从另一台局域网设备管理 NexusBox。

macvlan 旁路由模式只适用于 Linux Docker 主机；Docker Desktop、OrbStack 等 macOS/Windows 虚拟化环境无法把 macvlan 地址直接接入物理局域网。

KDocs 模式仍需在主路由添加 `198.18.0.0/16` 到 `LAN_IP` 的静态路由，并把客户端 DNS 指向 `LAN_IP`。完整网关模式则把客户端网关和 DNS 都设置为 `LAN_IP`。

## 配置与维护

查看状态和日志：

```bash
docker compose ps
docker compose logs -f mihomo-router
docker exec mihomo-router /opt/mihomo/mihomo -t -d /opt/config
```

更新镜像并保留订阅：

```bash
docker compose build --pull
docker compose up -d
```

首次启动会复制默认配置、规则、Zashboard 和 GEO 数据。以后重新创建容器不会覆盖 `docker-data/config` 中的内容。删除该目录会同时删除 NexusBox 账号、订阅和 Mihomo 运行配置，操作前应自行备份。

如果 53、7890、7891、9090 或 18080 已被占用，请修改 `.env` 中的桥接模式端口；macvlan 模式拥有独立 IP，不需要端口映射。

## 多架构构建

在已经配置 Buildx 的机器上构建双架构镜像：

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg MIHOMO_VERSION=v1.19.28 \
  -t YOUR_REGISTRY/pve-lxc-mihomo:latest \
  --push .
```

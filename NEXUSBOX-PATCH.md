# NexusBox 修补版说明

`bin/nexusbox-linux-amd64` 和 `bin/nexusbox-linux-arm64` 基于
[`Ladavian/NexusBox`](https://github.com/Ladavian/NexusBox) 提交
`c96970d7622c5e3cd5a0b111870db13ba1b90af6` 构建，沿用上游 MIT License。
安装脚本默认固定从本仓库提交 `b770b4281c874e03f2ad072ee9e75781bd9848a8` 下载二进制，避免 CDN 缓存旧文件后触发 SHA256 不匹配。

修补内容：

- 为当前 Mihomo 的 `PUT /configs?force=true` 请求补充 `payload` 字段。
- 增加 NexusBox 的 `/providers/proxies` 转发接口，供代理页读取 provider 节点及测速历史。
- 保留 Mihomo 节点测速接口的 HTTP 错误状态，不再把 `404` 当作成功结果。
- 代理页加载时合并 provider 节点历史，正常显示延迟或“超时”。
- 批量测速按 provider 去重，每个 provider 只触发一次 healthcheck。
- `DIRECT` 使用国内可达的 `https://connect.rom.miui.com/generate_204`；机场节点使用 HTTPS gstatic 测速地址。
- 融合模式每次保存都会同步全部订阅到 `proxy-providers`，修复添加第二条及后续订阅只显示在列表、没有进入 Mihomo 配置的问题。
- 修改或删除订阅时同步更新对应 provider，同时保留 raw YAML 中非 NexusBox 管理的自定义 provider。
- 订阅更新失败时检查 Mihomo 返回状态和节点数量，并在订阅卡片显示明确错误，不再长期停留在“流量信息不可用”。
- 日志页会加载 NexusBox 历史运行日志，同时继续接收 Mihomo 实时日志，默认显示 DEBUG 及以上级别。
- 单条订阅可启用“通过节点选择更新”，由已可用的代理节点访问受限订阅地址，避免给第一订阅造成循环依赖。
- 配置页在 NexusBox 或 Mihomo 刚重启时自动重试配置和 YAML 加载，不再依赖手动刷新。

构建命令：

```bash
cd web
npm ci
npm run build
cd ..
GOOS=linux GOARCH=amd64 go build -tags vue -ldflags="-s -w" -o nexusbox-linux-amd64 .
GOOS=linux GOARCH=arm64 go build -tags vue -ldflags="-s -w" -o nexusbox-linux-arm64 .
```

SHA256：

```text
amd64  51243c791e6b3ec277244e836cf494a29b3b93b94377631b971ee3f96737ddd2
arm64  cfad3e4393894a8739b5dadc48a3ab4379021b5f7b2d76139d35a7ce30617b2a
```

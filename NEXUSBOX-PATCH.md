# NexusBox 修补版说明

`bin/nexusbox-linux-amd64` 和 `bin/nexusbox-linux-arm64` 基于
[`Ladavian/NexusBox`](https://github.com/Ladavian/NexusBox) 提交
`c96970d7622c5e3cd5a0b111870db13ba1b90af6` 构建，沿用上游 MIT License。

修补内容：

- 为当前 Mihomo 的 `PUT /configs?force=true` 请求补充 `payload` 字段。
- 增加 NexusBox 的 `/providers/proxies` 转发接口，供代理页读取 provider 节点及测速历史。
- 保留 Mihomo 节点测速接口的 HTTP 错误状态，不再把 `404` 当作成功结果。
- 代理页加载时合并 provider 节点历史，正常显示延迟或“超时”。
- 批量测速按 provider 去重，每个 provider 只触发一次 healthcheck。
- `DIRECT` 使用国内可达的 `https://connect.rom.miui.com/generate_204`；机场节点使用 HTTPS gstatic 测速地址。
- 融合模式每次保存都会同步全部订阅到 `proxy-providers`，修复添加第二条及后续订阅只显示在列表、没有进入 Mihomo 配置的问题。
- 修改或删除订阅时同步更新对应 provider，同时保留 raw YAML 中非 NexusBox 管理的自定义 provider。

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
amd64  9427de7c5cacfe5518d3d4252bb72031501c3ae153fa66d7ae426dda6a20909d
arm64  8497a48f0824111ed1acfcf6c7124f73cbb20018c7e73dbba6980715ccf0af37
```

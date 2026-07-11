# NexusBox 修补版说明

`bin/nexusbox-linux-amd64` 和 `bin/nexusbox-linux-arm64` 基于
[`Ladavian/NexusBox`](https://github.com/Ladavian/NexusBox) 提交
`89579e531fb4ab0a19b428accfb3518c87ac9106` 构建，沿用上游 MIT License。

修补内容：

- 为当前 Mihomo 的 `PUT /configs?force=true` 请求补充 `payload` 字段。
- 增加 NexusBox 的 `/providers/proxies` 转发接口，供代理页读取 provider 节点及测速历史。
- 保留 Mihomo 节点测速接口的 HTTP 错误状态，不再把 `404` 当作成功结果。
- 代理页加载时合并 provider 节点历史，正常显示延迟或“超时”。
- 批量测速按 provider 去重，每个 provider 只触发一次 healthcheck。
- `DIRECT` 使用国内可达的 `https://connect.rom.miui.com/generate_204`；机场节点使用 HTTPS gstatic 测速地址。

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
amd64  9627886e27faaf40c7a0488d5835b7d7a20fb209f2cdab6dd1811ca8e865f7b5
arm64  9445c3e200ef591d284e36c22ff0827d3ae6ab25d6ca5089a01f125a304e4104
```

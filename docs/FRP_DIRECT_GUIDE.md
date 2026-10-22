# AirSIM：使用 frp 双端口远程直连

本地改造基线：`454a2bb6a12d9f7654cf58ba26d07d6dafa2c955`。

本方案允许 iPhone 在蜂窝网络下，通过自己的 frp 服务器访问安卓的控制和通话音频网关。手动端点不依赖 Bonjour/mDNS。安卓使用本改造源码构建的 Standalone APK，且需先完成本地配对、默认电话角色设置、Shizuku 授权和双向语音验收。本次修改不改变安卓的私网来源限制，仅补齐经现有 HMAC 鉴权的 `/api/push/mode` 白名单，使 iPhone 可以通知安卓停用云端心跳。

## 数据路径

```text
iPhone（4G/5G 或 Wi-Fi）
  ├─ HTTPS 控制 → airsim.example.com:17592
  └─ TLS/TCP 音频 → airsim.example.com:17593
          ↓
自有 frps（仅转发 TLS 字节）
          ↓ frp TCP 隧道
内网常驻电脑：frpc → 127.0.0.1:17592 / :17593 → stunnel
          ↓ 解密后经局域网连接
安卓 Wi-Fi IP：7592 控制 / 7593 音频
          ↓
SIM 卡 / 运营商
```

控制与音频公网端口可分别更换；必须与 frpc 配置和 iPhone 设置对应。两条链路都必须使用 TLS。HMAC 继续保护请求和音频握手，时间戳/nonce 防重放继续生效；HMAC 本身不加密音频，因此不能简单把明文 7592/7593 暴露到公网。

## 1. 安卓与网络准备

1. 在同一局域网完成原项目的 Android/iPhone 配对，验证本地拨出、接听和双向音频。
2. 给安卓预留固定 DHCP 地址，如 `192.168.1.50`。安卓和常驻电脑连接可互访的内网；关闭 AP 客户端隔离，避免访客网络。
3. 网关优先监听控制 TCP `7592`、音频 TCP `7593`。**原版在端口被占用时会选择其他端口**，部署前检查安卓的 `vowlan_control_listening` / `vowlan_pcm_listening` / `vowlan_ready` 日志，按实际端口填写 stunnel；发生变化后需同步更新。不要将 AVF/内部音频端口 `8575/8576/7580` 映射到公网。
4. 常驻电脑不能休眠，安卓需维持前台服务和 Shizuku；重启后无线调试/Shizuku 通常需要重新启动。
5. 在安卓端也确认“云端模式”关闭。仅关闭 iPhone 云端不能保证安卓停止原来的 Relay 心跳；本改造在直连健康检查通过后发送停用命令，但网络失败时无法确认安卓已执行。纯直连建议从原项目的“仅本地模式”开始配对，不填写作者 Relay 资料。

## 2. 准备自己的域名和证书

将 `airsim.example.com` 的 DNS A 记录指向你的 frps 公网服务器（如使用 Cloudflare DNS，设为仅 DNS，普通橙云 HTTP 代理不支持这里的音频 TCP）。在内网常驻电脑准备覆盖该域名的可信 TLS 证书、完整证书链和私钥，例如通过 ACME DNS-01 签发。

证书用于两个端口，安装在 stunnel 所在的内网电脑上。客户端使用系统证书链及主机名验证，没有跳过验证的开关。公网 IP 也可填，但证书必须包含该 IP 的 SAN，通常使用域名更方便。不支持 IPv6 字面量或带 URL 路径的配置。不要把证书私钥或 frp token 放进源码仓库。

证书需自动续期，并在续期后重新加载 stunnel。Windows 证书路径可使用正斜杠；Linux/macOS 按实际绝对路径修改。

## 3. 内网电脑运行 stunnel 与 frpc

配置示例位于：

- `deploy/direct-frp/stunnel.example.conf`
- `deploy/direct-frp/frpc.example.toml`

安装 stunnel，将示例复制为自己的配置，修改证书路径、安卓 IP 和实际端口。stunnel 接收端只监听本机回环，frpc 与 stunnel 必须在同一台电脑上。连接安卓时，安卓看到的来源是电脑的私网 IP，因此不需要取消原项目的私网客户端校验。

启动命令示例（按实际安装目录执行，Windows 可在 stunnel GUI 中加载配置）：

```sh
stunnel /absolute/path/to/stunnel.conf
frpc verify -c /absolute/path/to/frpc.toml
frpc -c /absolute/path/to/frpc.toml
```

如果已经在运行 frpc，把示例中的两个 `[[proxies]]` 加入已有配置即可，沿用你的 `serverAddr`、认证方式及 token；不需要启动第二个冲突实例。frps 必须允许 TCP 代理，以及分配的两个公网端口（包括其 `allowPorts` 策略）。公网服务器防火墙/安全组开放 TCP 17592、17593；不需要 UDP，也不需要 HTTP 类型代理或 URL 路径重写。

stunnel 位于内网端，因此从 iPhone 到内网电脑保持 TLS，frps 无需通话解密密钥。电脑到安卓这一段仍是原协议的局域网明文链路，需要可信局域网。仅使用 frp 的 `transport.tls` 不能替代两个公网入口的 TLS。

## 4. 构建 iPhone 客户端

交付中的 `AirSIM-Standalone-frp-debug.apk` 是本地调试签名的安卓包，包名仍为 `com.airsim.phonecontrol.standalone`，最低 Android 10。它与作者或你现有安装的签名可能不同，不能保证覆盖安装；先保存配对和配置资料，不要直接卸载旧版。自有正式部署应使用自己保存的签名密钥重新构建。此 APK 已做签名验证，尚未真机安装。

在 Mac 打开 `iOS/AirSIM.xcodeproj`，按原项目说明使用自己的开发者身份和 Bundle ID 签名。需要同时处理 Watch 和 Live Activity 扩展的签名。本交付包含源码，不包含已签名 IPA 或作者身份。

建议先执行新增回归测试（模拟器名称以本机为准）：

```sh
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO test
```

测试覆盖手动主机/端口校验、TLS 音频路由、设置持久化及无效输入不覆盖已有配置、Watch TLS 参数和旧的私网发现限制。此命令尚未在本次 Windows 环境中执行，不能用语法检查替代 Xcode 编译或真机验收。

## 5. iPhone 设置

打开“设置 → frp / 内网穿透直连”，输入：

| 字段 | 示例 |
| --- | --- |
| 域名或 IPv4 | `airsim.example.com`（不带 `https://`、端口或路径） |
| 公网控制端口 | `17592` |
| 公网音频端口 | `17593` |

点击“保存并启用仅直连（停用云端）”。它会启用原项目的“仅本地模式”，关闭 Relay/APNs/PushKit/CallKit 注册，并清除旧端点缓存与事件游标。这里的“仅本地模式”包含通过 frp 的手动直连，不要求 iPhone 与安卓在同一 Wi-Fi。手动模式不再启动 Bonjour，也不会在手动配置无效时偷偷回退到自动发现。

保存后查看连接状态，必须健康检查及配对密钥验证通过才算在线。保存成功不代表链路已通。通话中设置区禁用，避免一通电话中途切换目标。点击“停用远程直连，恢复局域网发现”可恢复原局域网发现；它不会自动重新开启云端。

## 能力与限制

- App 活跃时可通过原有电话/短信 API 使用安卓，控制与音频都走自己的链路。
- **完全不使用 Relay/APNs 时，不能保证 iPhone 锁屏、应用挂起或被结束后还能收到来电。** frp 无法唤醒被 iOS 挂起的 App；新增端点没有改变这一点。短信后台通知也一样受限。
- 如需后台来电，可再部署自己的原项目 Relay 和 APNs 凭据，关闭“仅本地模式”并开启云端。手动直连健康时仍优先用于控制/音频；它不可达时原项目会允许整通电话选择 Relay。这种组合仍不依赖作者服务器，但不能声称 Relay 只承担推送。
- 本次也传递 Watch 音频端点的 TLS 标记；Watch 端需升级为同一套源码，配套 iPhone 的控制通道仍必须可用。未实测 Watch 远程通话。
- 不支持通话中从直连切换到 Relay；断网后须结束当前通话，再发起新通话。

## 分层排障与验收

1. 在常驻电脑验证安卓控制网关可达：`curl -i http://192.168.1.50:7592/v1/health`。未签名请求应返回鉴权失败（通常 401），不能以这个请求获取 200 作为目标；连接超时表示 IP/端口/监听或局域网有问题。
2. 启动 stunnel，确认能读取证书和私钥；启动 frpc，确认两个代理均上线。可用 `openssl s_client -connect airsim.example.com:17592 -servername airsim.example.com -verify_hostname airsim.example.com -verify_return_error` 检查控制端口证书，再检查 17593。测试中不要关闭证书验证。
3. 将 iPhone 的 Wi-Fi 关闭，只用蜂窝数据，在 App 中验证手动端点健康检查、短信发送和收件方实际收到。
4. 用非紧急测试号码拨打，确认双向音频、静音、DTMF 和挂断，检查公网电脑上两个端口均有连接。
5. 保持 App 前台，向安卓 SIM 号码拨入，确认 iPhone 可接听和双向讲话。
6. 中断 frp 或安卓 Wi-Fi，确认没有把通话静默迁移到其他目标；恢复后重新拨打。
7. 分别测试锁屏、后台、进程被终止、电脑/安卓重启；仅直连模式不能将这些场景的来电送达作为保证。

本方案尚未连接用户的 frps、证书、安卓或 iPhone 实测。它不替代系统紧急通信能力。原项目的 PolyForm Noncommercial 许可证和 Required Notice 继续适用。

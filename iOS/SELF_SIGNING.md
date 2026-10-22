# 下载与自行签名

1. 打开本仓库 Actions → Build unsigned iPhone IPA。
2. 在成功的运行页面底部 Artifacts 下载 `AirSIM-iPhone-unsigned-运行编号`。
3. 解压下载文件，得到 `AirSIM-iOS-0.9.6-frp-unsigned.ipa`。

这是实机 arm64 编译的未签名 IPA，不是模拟器包，无需在 Actions 配置 Apple 证书、开发者账号或密码。必须签名后安装。

包中保留主 App、Watch App 和 Live Activity 扩展。签名工具必须支持所有嵌套 App/扩展，不能只签主程序；如修改 Bundle ID，需要同时修改主 App、`.watchkitapp`、`.liveactivity` 以及 Watch 的 companion 标识，并使用匹配的配置描述文件和权限。若签名方式不支持 Watch/扩展，可在签名前用签名工具移除相应组件，移除后对应功能不可用。受限签名可能无法获得 PushKit/APNs 等权限；frp 仅直连模式不依赖这些后台推送能力。

首次安装仍需在同一局域网完成安卓配对，再在“设置 → frp / 内网穿透直连”中填写自己的域名和两个公网端口。控制和音频入口都必须使用 TLS，部署见 `docs/FRP_DIRECT_GUIDE.md`。

新版支持自签 TLS：为 `vip.gz.frp.one` 预填了本地生成证书的公开 SHA256 指纹。将本地交付的证书和私钥部署到内网 stunnel；更换证书后在设置里更新指纹。私钥不包含在 IPA 或仓库中，详见 `docs/SELF_SIGNED_TLS.md`。

仅直连无法保证锁屏后台来电唤醒。Actions 构建成功只证明编译和打包成功，不代表已经通过真机通话验收。

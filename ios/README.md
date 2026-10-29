# QuotaMeter for iOS

QuotaMeter 的 iPhone 版本，用来查看 API 中转余额、Token 用量、每日使用记录和限额。
当前版本：**v1.2.5**（Build 1.2.5）

界面为三个底部标签页：**额度 / 平台 / 我的**，适配 iOS 17 及以上，仅支持 iPhone 竖屏。

## 功能

### 额度

- **概览**：钱包余额与连接状态、累计花费、今日 / 累计 token、今日 / 累计请求
- **用量**：最近 10 天用量柱状图 + 每日明细（日期、请求次数、Token 数）
- **限额**：rate limit / quota 信息
- 顶部一键刷新，多 API 之间用胶囊标签快速切换
- 定时轮询刷新，默认每 30 秒

### 平台

- 已绑定平台卡片化展示（DeepSeek、自定义兼容 API 等）
- 点击直接调用系统 Safari 打开对应平台官网或用量页
- 当前使用中的平台带「当前」标记

### 我的

- 本地账户信息与「账户数据隔离」说明
- 外观模式：跟随系统 / 浅色 / 深色，切换后立即生效并保存在本机
- 已绑定 API 列表，可切换当前 API、一键刷新全部 API
- 问题反馈与 GitHub Issues 直达入口

### 通用能力

- 支持 OpenAI-compatible 接口、OpenRouter、DeepSeek
- 支持供应商 Usage / 官网访问令牌（按供应商配置）
- 支持自定义 `Usage Path`，并自动探测常见的 `/v1/usage`、`/usage`、`/api/usage`、`/user/usage`、`/account/usage`、`/billing/usage`、`/balance`、`/user/balance`
- 对仅提供余额接口的供应商，记录本机首次成功刷新之后观测到的余额消耗（不会伪造成 token 或请求数）
- API Key 与访问令牌只保存在本机 Keychain，不写入任何配置文件

## 安装

本目录提供的是**未签名 IPA**（`QuotaMeter-iOS-v1.2.5-unsigned.ipa`），因为开源项目没有 Apple 开发者证书。

未签名包不能直接双击安装，需要先用自己的证书重签，或用自签工具侧载：

| 方式 | 说明 |
| --- | --- |
| Sideloadly | Windows / macOS 均可，用免费 Apple ID 签名后安装到手机，有效期 7 天 |
| AltStore / SideStore | 手机上自签，需要一台电脑完成首次配对 |
| TrollStore | 仅限支持的系统版本，签一次长期有效 |
| Xcode | 直接打开本目录工程，用自己的 Team 签名后真机运行 |

安装后在 `设置 → 通用 → VPN 与设备管理` 中信任对应证书。

> API Key 只保存在手机本机 Keychain 中，不会上传到任何服务器。换机或删除 App 后需要重新填写。

## 从源码构建

仓库已附带可直接打开的 `QuotaMeter.xcodeproj`（objectVersion 56，兼容 Xcode 14 及以上）：

```bash
cd ios
open QuotaMeter.xcodeproj
```

`project.yml` 是工程配置源（[XcodeGen](https://github.com/yonaskolb/XcodeGen) 格式），只在需要改动工程结构时才重新生成：

```bash
brew install xcodegen
cd ios
xcodegen generate
```

> 注意：xcodegen 2.46 及以上版本会输出 objectVersion 77 的工程格式，需要 **Xcode 16+** 才能打开。使用 Xcode 15 及以下时请直接使用仓库内附带的工程文件，不要重新生成。

也可以直接用命令行构建未签名真机包：

```bash
cd ios
xcodebuild -project QuotaMeter.xcodeproj \
  -scheme QuotaMeter \
  -sdk iphoneos \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO
```

产物在 `build/Build/Products/Release-iphoneos/QuotaMeter.app`，把 `.app` 放进 `Payload/` 目录后压缩并改名为 `.ipa` 即可。

## 目录结构

```text
ios/
├── project.yml                    # XcodeGen 工程配置（iOS 17.0，com.codex.quotameter）
├── QuotaMeter.xcodeproj           # 可直接打开的工程（objectVersion 56）
├── QuotaMeter.swift               # 共享数据层与模型
├── QuotaMeterV2.swift             # 当前使用的 SwiftUI 界面实现
├── QuotaMeteriOS.swift            # iOS 入口与平台适配
├── Assets.xcassets/               # App 图标与资源
├── QuotaMeterTests/               # 用量解析单元测试
├── QuotaMeterUITests/             # UI 测试
├── scripts/                       # 图标生成脚本
├── build.sh                       # 构建脚本
└── QuotaMeter-iOS-v1.2.5-unsigned.ipa
```

## 与桌面版的差异

| | macOS | Windows | iOS |
| --- | --- | --- | --- |
| 形态 | 菜单栏常驻 | 系统托盘 | 底部三 Tab |
| 凭据存储 | Keychain | DPAPI | Keychain |
| 最低系统 | macOS 13 | Windows 10 | iOS 17 |
| 分发方式 | DMG | EXE | 未签名 IPA |

## 截图

| 概览 | 用量 | 添加 API |
| --- | --- | --- |
| ![概览](../screenshots/ios/ios-01-overview.jpg) | ![用量](../screenshots/ios/ios-02-usage.jpg) | ![添加 API](../screenshots/ios/ios-03-add-api.jpg) |

| 平台 | 我的 |
| --- | --- |
| ![平台](../screenshots/ios/ios-04-platforms.jpg) | ![我的](../screenshots/ios/ios-05-me.jpg) |

## 安全说明

- API Key 与访问令牌仅保存在本机 Keychain
- 不同账户的 API Key、平台令牌、刷新设置与反馈内容互相隔离
- 不采集设备标识，不上报使用数据
- 平台跳转通过系统 Safari 完成，App 内不注入任何网页脚本

## 许可证

与仓库根目录一致，见 [LICENSE](../LICENSE)。

# QuotaMeter

QuotaMeter 是一个 macOS 菜单栏小工具，用来查看 API 中转余额、Token 用量、每日使用记录和限额。

## 功能

- 菜单栏常驻，点击即可展开详情
- 实时轮询刷新余额与用量
- 显示今日 / 累计 token、请求数、费用
- 显示每日使用记录
- 显示 rate limit / quota 信息
- 支持 OpenAI-compatible 接口
- 支持 OpenRouter
- 支持自定义 `Usage Path`
- 密钥保存到本机 Keychain
- 可选读取本地 `config.json`

## 支持平台

- macOS 13 或更高版本
- Apple Silicon / Intel
- 建议使用 Xcode 15+ 或已安装 Command Line Tools

## 安装

### 方式一：从源码构建

```bash
bash build.sh
open build/QuotaMeter.app
```

### 方式二：使用本地配置文件

把 `config-example.json` 复制为：

```bash
mkdir -p "$HOME/Library/Application Support/QuotaMeter"
cp config-example.json "$HOME/Library/Application Support/QuotaMeter/config.json"
```

然后填写你自己的 Base URL 和 API Key。不要把 `config.json` 提交到仓库。

## 使用步骤

1. 打开 QuotaMeter
2. 点击菜单栏图标
3. 打开设置窗口
4. 填写 `Base URL`
5. 填写 `API Key`
6. 需要时选择接口类型和 `Usage Path`
7. 点击“保存并刷新”

### 常见填写示例

- 兼容中转：`Base URL = https://your-api.example.com`，接口类型选“兼容接口”，`Usage Path = /usage`
- OpenRouter：接口类型选“OpenRouter”，`Base URL = https://openrouter.ai/api`

## macOS 打开未签名 App

如果系统拦截未签名应用，可以用下面任一方式：

1. 右键 `QuotaMeter.app`，选择“打开”
2. 到 `系统设置 -> 隐私与安全`，点“仍要打开”
3. 终端执行：

```bash
xattr -dr com.apple.quarantine build/QuotaMeter.app
```

## 截图

项目截图：

![QuotaMeter 主界面](./screenshots/main.png)

![QuotaMeter 设置页](./screenshots/settings.png)

如果要补充错误状态截图，可放入 `screenshots/error.png`。

## 安全说明

- API Key 默认保存在本机 Keychain
- 不会额外启动后台 Helper 或登录项
- 退出 App 后，状态栏图标和轮询都会结束
- `config.json` 不要提交到仓库

## 开发说明

```bash
bash build.sh
```

构建产物会输出到 `build/QuotaMeter.app`。

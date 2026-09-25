# 🍪 UniversalCookie - iOS 通用 Cookie 提取与 GitHub Secrets 精准直推助手

![Platform](https://img.shields.io/badge/Platform-iOS%2015.0%2B-blue.svg)
![Arch](https://img.shields.io/badge/Arch-arm64%20(Rootless)-brightgreen.svg)
![Injection](https://img.shields.io/badge/Injection-TrollFools%20%7C%20Theos-orange.svg)
![License](https://img.shields.io/badge/License-MIT-purple.svg)

**UniversalCookie** 是一款专为 iOS 逆向与自动化脚本玩家打造的通用型生产力插件。通过 **TrollFools**（或越狱环境）注入到任意目标 App 后，只需进入 App 的「个人中心 / 我的」页面点击悬浮球，即可智能提取、归并核心登录 Cookie，并在手机端直接完成公钥加密，**一对一精准直推更新到你指定的 GitHub 仓库 Secret 中**。

无需抓包软件（Stream / Thor / Charles），无需电脑中转，也无需在每个 GitHub 仓库里编写繁琐的接收更新 Workflow！

---

## ✨ 核心特性

* 🎯 **纯手动按需抓取（告别杂乱）**
  * 摒弃无休止的后台自动抓取。平时悬浮球静默待机，当你进入 App「个人中心」页面后点击悬浮球，才执行一次性快照抓取，指哪打哪。
* 🧠 **一级主域名强制归并 & 高价值凭证置顶**
  * **智能归并**：自动将复杂的子域名（如 `api.m.jd.com`、`wq.jd.com`、`h5.m.taobao.com`）统一收敛合并至一级主域名（`jd.com`、`taobao.com`），同名字段自动去重。
  * **噪音过滤**：内置广告、CDN 与第三方统计域名黑名单（如 `alicdn`、`mmstat`、`umeng`、`sensorsdata` 等），自动剔除无用干扰项。
  * **智能推荐**：自动扫描包含 `pt_key`、`pt_pin`、`auth`、`token`、`user`、`login`、`session`、`cookie2`、`sid` 等关键字的凭证，打上 `🌟` 标签并强制置顶。
* 📡 **三通道全网通嗅探**
  * 同时覆盖 `NSHTTPCookieStorage`（原生网络栈）、`WKWebsiteDataStore`（H5 / WKWebView 容器）以及底层 `NSURLSession` / `__NSURLSessionLocal` 请求头拦截，通杀各类混合开发 App。
* 🔐 **iOS 端原生 SealedBox 加密直推（免中转工作流）**
  * 内置零外部依赖的纯 C 语言 `libsodium` (`crypto_box_seal`) 加密引擎（`sodium_seal.h`）。
  * 直接在手机本地使用 GitHub 仓库公钥完成 `Curve25519 + XSalsa20 + Poly1305 + BLAKE2b` 加密，调用 GitHub 官方 `PUT /repos/{owner}/{repo}/actions/secrets/{secret_name}` 接口完成秒级覆盖更新。
* 📂 **多仓库 & 多 Secrets 三级动态联动**
  * 只需配置一次 GitHub PAT Token，插件自动拉取你名下**所有仓库（含私有仓库）**，点选仓库后自动加载该仓库下**已有的全部 Secrets 列表**，并支持在手机端直接新建 Secret。
* ⚡ **持久化一对一记忆绑定**
  * 在当前 App 完成一次 `域名 ➔ 仓库 ➔ Secret` 推送后，插件自动记住该映射关系。下次打开该 App，点击 **「⚡ 一键推送最新凭证」** 即可秒级更新。
* 🪟 **全屏穿透独立窗口 (`UCPassthroughWindow`)**
  * 采用独立高优层级穿透窗口，无视淘宝、京东等巨型 App 复杂的内部视图树与开屏广告遮挡；搭配非阻塞式顶部悬浮胶囊提示（HUD）与仓库列表内存缓存，实现零延迟的多级菜单返回与切换体验。

---

## 📱 交互预览与操作流程

### 1. 悬浮球手势说明
| 手势操作 | 功能说明 |
| :--- | :--- |
| **单击悬浮球** | 立即执行一次当前页面 Cookie 快照抓取，并展开主菜单 |
| **按住拖拽** | 自由移动悬浮球位置 |
| **双指双击悬浮球** | 隐藏悬浮球（重启 App 后恢复显示） |

### 2. 三步精准推送流程
1. **配置令牌**：复制拥有 `repo` 权限的 GitHub Personal Access Token (`ghp_xxxx`)，点击悬浮球 ➔ `⚙️ 配置 GitHub 访问令牌 (PAT)` ➔ `📋 直接从剪贴板读取并保存`。
2. **首次绑定推送**：
   * 打开目标 App 并进入「我的 / 个人中心」页面，点击悬浮球。
   * 点击 `🎯 查看抓取结果 ➔ 推送到 GitHub`。
   * **第 1 步**：选择置顶的 `🌟` 核心主域名凭证。
   * **第 2 步**：在动态加载的列表中选择你的目标 GitHub 仓库。
   * **第 3 步**：选择该仓库下要更新的目标 Secret（如 `JD_COOKIE`、`SHANBAY_COOKIE` 等，或点击新建）。
3. **后续日常更新**：
   * 以后 Cookie 过期需要更新时，只需打开 App 进个人中心，点开悬浮球直接点击第一项 **「⚡ 一键推送 [xxx.com] 最新凭证」** 即可！

---

## 🛠️ 安装与注入方式

### 方式一：使用 TrollFools 注入（强烈推荐）
1. 前往本仓库的 [Releases](../../releases) 页面，下载最新编译好的 `UniversalCookie.deb` 或 `UniversalCookie.dylib`。
2. 在安装有 TrollStore 的设备上打开 **TrollFools**。
3. 在应用列表中找到你需要提取 Cookie 的目标 App（如：京东、淘宝、扇贝、掌上华医等）。
4. 点击 **Inject（注入）**，选择下载好的 `.deb` 或 `.dylib` 文件完成注入。
> **⚠️ 注意**：如果你在多巴胺（Dopamine）越狱环境下使用了 `Choicy` 等插件对目标 App 开启了「屏蔽插件注入 (Disable Tweak Injection)」，请先关闭该 App 的屏蔽开关，否则注入的动态库将无法加载。

### 方式二：越狱环境全局安装
如果你希望在越狱环境下通过 Sileo / Zebra 或终端直接安装，请务必先修改 `UniversalCookie.plist`，将你需要注入的目标 App 的 Bundle ID 填入 `Bundles` 数组中，随后执行安装。

---

## 💻 从源码编译 (Build from Source)

本项目采用 **Theos** 构建，内置纯 C 编写的 `sodium_seal.h`，**无需额外安装或交叉编译 `libsodium` 静态库**，开箱即编。

### 1. 环境准备
* 已配置好 **Theos** 开发环境（支持 iOS 端本地编译或 macOS / Linux 交叉编译）。
* 需要 iOS 15.0 及以上版本的 SDK（如 `iPhoneOS15.6.sdk`）。

### 2. 项目文件结构
* `Tweak.x`：插件核心代码（UI 穿透窗口、多通道嗅探、一级域名归并、GitHub API 交互）。
* `sodium_seal.h`：零依赖纯 C 实现的 `libsodium` `crypto_box_seal` 加密算法库。
* `Makefile`：Theos 编译规则文件（默认 `arm64` + `rootless` 架构）。
* `control`：软件包描述信息。
* `UniversalCookie.plist`：动态库加载过滤配置。

### 3. 编译打包
克隆本仓库并在项目根目录下执行：
```bash
git clone https://github.com/你的用户名/UniversalCookie.git
cd UniversalCookie
make package
```
编译成功后：
* 生成的 `.deb` 安装包位于 `./packages/` 目录下。
* 生成的 `.dylib` 动态库位于 `./.theos/obj/debug/arm64/UniversalCookie.dylib`。

---

## 🔒 隐私与安全声明

* **本地直连**：本插件的所有网络请求均由你的 iOS 设备直接发往 GitHub 官方 API (`https://api.github.com`)，绝不经过任何第三方中转服务器。
* **端到端加密**：抓取到的 Cookie 在手机本地内存中直接通过 GitHub 下发的仓库公钥进行 `SealedBox` 非对称加密，变成密文后才通过 HTTPS 上传，即使在网络传输层也无法被解密还原。
* **Token 权限建议**：建议在 GitHub 生成 PAT Token 时仅勾选必要的 `repo` 权限，并妥善保管你的设备。

---

## 📄 开源协议 (License)

本项目基于 [MIT License](LICENSE) 协议开源，仅供个人学习 iOS 逆向工程与自动化技术交流使用，请勿用于任何非法用途。

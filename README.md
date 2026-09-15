# noswoosh-pro

> **本仓库是 [mmathys/noswoosh](https://github.com/mmathys/noswoosh) 的 fork。** 上游由
> [Maximilian Mathys（@mmathys）](https://github.com/mmathys) 开发维护 —— 合成 Dock 滑动手势的
> 技巧、拦截真实三指滑动的事件 tap、macOS 27 的 IOHID 载荷、空桌面 yank 守卫、安装脚本与文档
> 全部出自上游，**在此表示衷心感谢**。本 fork 只在其基础上加了一件事：**切换到位于其他空间的应用**
> （Cmd+Tab、[skhd](https://github.com/koekeishiya/skhd) / `open -b` 快捷键、点 Dock 图标）同样瞬时完成
> —— 在该应用的窗口 order in 之前先把空间切过去。其余部分与上游保持一致，用 `git merge upstream/main` 同步。
>
> 🇬🇧 [English README](README.en.md)
>
> ```sh
> brew install --cask KylehsuXu/tap/noswoosh-pro
> ```

空间切换**无动画、瞬时完成**：**三指滑动**、**Ctrl+←/→**，以及**切换到位于其他空间的应用**。
支持 **macOS 26.6+ 与 27**，不需要关闭 SIP，也不需要打开全局"减弱动态效果"。

[![Latest release](https://img.shields.io/github/v/release/KylehsuXu/noswoosh-pro?color=blue)](https://github.com/KylehsuXu/noswoosh-pro/releases/latest)
[![MIT license](https://img.shields.io/github/license/KylehsuXu/noswoosh-pro?color=blue)](LICENSE)
![macOS 26.6+ / 27](https://img.shields.io/badge/macOS-26.6%2B%20%2F%2027-lightgrey)

![对比：macOS 原生空间切换动画 vs noswoosh 瞬时切换](assets/demo.gif)

## 安装

```sh
brew install --cask KylehsuXu/tap/noswoosh-pro
```

Homebrew 7 默认不信任第三方 tap，需要先 trust：

```sh
brew trust --cask KylehsuXu/tap/noswoosh-pro
brew install --cask KylehsuXu/tap/noswoosh-pro
noswoosh-pro setup
```

`noswoosh-pro setup` 做一次性的系统配置：关闭系统自带的动画 Ctrl+方向键快捷键，并安装登录守护进程。
它必须单独执行，因为 Homebrew 会把 cask 的安装步骤放进沙箱 —— 之前在 `postflight` 里调用它的方案会
被 SIGKILL 掉（静默失败），系统快捷键依然处于开启状态。

然后**授予辅助功能权限**（macOS 用这道门禁管控合成事件，无法脚本化）：首次启动会弹窗，直接允许即可；
如果误关了弹窗，noswoosh 会替你打开 **系统设置 → 隐私与安全性 → 辅助功能**，在那里手动添加
`/Applications/noswoosh-pro.app`。

之后守护进程会在一秒内自动识别到授权。**三指滑动**、**Ctrl+←/→** 和**切换到其他空间的应用**
（Cmd+Tab、skhd）都会变成瞬时切换。

> 升级提示：`brew upgrade --cask noswoosh-pro` 会触发本 cask 的卸载钩子，登录守护进程会被一并移除，
> 升级后重新执行一次 `noswoosh-pro setup` 即可。辅助功能 / 设备控制授权会保留（release 使用稳定证书签名）。

<details>
<summary><b>改为从源码构建</b></summary>

需要 Xcode Command Line Tools（`xcode-select --install`）。

```sh
git clone https://github.com/KylehsuXu/noswoosh-pro.git
cd noswoosh
./scripts/install.sh
```

安装脚本会把 `noswoosh.swift` 编译到 `~/.local/bin/`，执行 `noswoosh-pro setup`，并安装一个
LaunchAgent（`xu.max.noswoosh-pro`），日志写在 `~/Library/Logs/noswoosh-pro.log`。
辅助功能权限要授予 `~/.local/bin/noswoosh-pro`。

设置 `NOSWOOSH_SIGN_IDENTITY="Developer ID Application: ..."` 可以给本地构建签名，这样授权在重新构建后仍然有效。

</details>

## 使用

三种方式，全部瞬时：

- **三指左右滑动** —— 你熟悉的空间手势，只是没有动画。noswoosh 拦截真实滑动并替换成瞬时切换；
  竖直方向（调度中心、App Exposé）不受影响。
- **Ctrl+→ / Ctrl+←** —— 右/左切换一个空间。
- **切换到位于其他空间的应用** —— Cmd+Tab、点 Dock 图标，或任何执行 `open -b` 的快捷键
  （[skhd](https://github.com/koekeishiya/skhd) 的应用快捷键就是这个形式）。守护进程会在应用
  把窗口 order in 之前先切到那个空间，因此没有可播放的过渡动画。（这是本 fork 新增的能力，
  且只在守护进程里生效：`noswoosh-pro left/right` CLI 退出太快，来不及抢占。）

在空间列表的首/末位会做边界钳制，所以不会出现橡皮筋回弹。

多显示器行为与原生一致：切换作用于**鼠标指针所在**的显示器，而不是键盘焦点所在的显示器；
关闭"显示器各自拥有独立空间"时，所有显示器共享一套空间并一起切换。

也可以把它当 CLI 用（脚本、调试）：

```sh
noswoosh-pro list      # 输出 "space 2 of 4"
noswoosh-pro right     # 切一次然后退出
noswoosh-pro left
noswoosh-pro setup     # 应用系统配置（teardown 可撤销）
noswoosh-pro teardown
noswoosh-pro version     # 也支持 -v / --version
noswoosh-pro --help      # 用法（-h 同义）
```

想绑定自定义快捷键，就在任何"执行命令"的热键工具里绑定 `noswoosh-pro left` / `noswoosh-pro right`：
[skhd](https://github.com/koekeishiya/skhd)、[Karabiner-Elements](https://karabiner-elements.pqrs.org)、
[Hammerspoon](https://www.hammerspoon.org) 或 [Raycast](https://www.raycast.com)。
一次切换大约 100ms 落地，和内置的 Ctrl+←/→ 相比没有速度损失。

## 工作原理

macOS 没有官方办法**只**关掉空间切换的滑动动画：

- 老的 `defaults write com.apple.dock workspaces-swoosh-animation-off` 从 Lion（2011）起就失效了。
- **减弱动态效果**能用，但它是全局的，而且是交叉淡入淡出，不是瞬时切换。
- 单独给 Dock 关动画的辅助功能设置在 iOS 上有，macOS 没有。
- yabai 能做到，但需要部分关闭 SIP。

noswoosh 采用 [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher)、
[WhichSpace](https://github.com/gechr/WhichSpace) 和 BetterTouchTool 的思路：合成一个
**进度近乎为零、速度极高**的 Dock 触控板滑动手势。切换仍然走 Dock 自己的管线（因此调度中心、
焦点、壁纸、Dock 状态都保持一致），但动画没有距离可走，于是表现为瞬时。

两个输入源汇入同一个切换核心：**事件 tap** 监听真实三指水平滑动，在 Dock 播放动画前把它吞掉并发出
瞬时切换 —— 所以自然滑动依然可用，只是不再滑；**Ctrl+方向键热键**直接发出同一个切换。两者互相独立：
即便 tap 被系统禁用，Ctrl+←/→ 依然工作。

**macOS 27** 收紧了校验：合成 Dock 滑动必须携带一段序列化的 IOHID 载荷，老办法不带，于是 27 上会静默
失效。noswoosh 运行时会检测系统版本，在 27 上附带这段载荷（布局逆自
[joshuarli/iss](https://github.com/joshuarli/iss)），在 26 上沿用原来的轻量路径。

> 关于名字：*swoosh* 是 Apple 自己对空间滑动动画的称呼，来自早已消失的 Snow Leopard 设置
> `workspaces-swoosh-animation-off`。这个项目就是把它复活。

### 应用激活时的抢占切换（本 fork 的能力）

上游只在手势上做切换；本 fork 额外处理**激活一个位于其他空间的应用**：Cmd+Tab、点 Dock 图标，或任何
执行 `open -b` 的快捷键（skhd 的应用快捷键都是这个形状）。正常情况激活这类应用会把它的空间一起拖过来，
带一段滑动动画；这里守护进程会先察觉到激活，自己先切到那个空间，等应用把窗口 order in 时空间已经是当前
空间，跟随规则也就没有东西可动画了。

这次抢占同样要发一个真实手势，而合成滑动并不是"发出即生效"：Dock 自己的空间模型要 **约 38ms 之后**
才读到新空间。在这个窗口内发出的第二个切换，方向是按 Dock 已经离开的 index 算出来的，一旦落在空间列表
的两端，就是一次 Dock 必须 clamp 的滑动 —— 实测表现为**约 500ms 黑屏**，同时空间列表冻结直到恢复。
因此守护进程**同一时刻只允许一个切换在途**：等 Dock 的模型确认之后才发下一个；这期间到达的请求先停放，
20ms 后按最新一次读取重新评估，而不是盲发。这也是"快速连按 Cmd+Tab / skhd 依然瞬时、不再黑屏"的原因；
同样地，连按时偶尔会直接落到你最后激活的那个应用所在的空间、而不是每个中间空间都弹一遍 —— 这是刻意的：
最新的那次激活优先。

### 空桌面被"拽走"的问题

上游在开发中发现了一个用原生切换也能复现的 macOS 行为：**切到一个没有任何窗口的桌面，约 400ms 后
系统会把你拽到另一个桌面。** 链条（已在 Dock 日志与 app 激活埋点中确认）：

1. 落在一个没有窗口的空间时，macOS 会挑一个应用激活它。
2. 该应用把主窗口 order in —— 而那个窗口在另一个空间上。
3. Dock 的"窗口 order in 跟随"规则触发（日志里是 `switching to space N for window(...) ordered on
   non-visible space`），于是你被拽到那个窗口所在的空间。

省事的修法是 `defaults write com.apple.dock workspaces-auto-swoosh -bool NO`，让 Dock 根本不注册那个
通知。noswoosh 在 1.6.4 之前就是这么干的 —— 代价是**点击 Dock 图标跳转到窗口所在空间**的能力一起没了。
反汇编 Dock 能看到原因：这条规则的切换器只有一个调用者，就是那个通知块。一个偏好设置，两种行为，无法拆分。

所以从 1.7.0 起 noswoosh 不再动这个偏好，改为消除**起因**：一旦落在没有窗口可聚焦的空间，守护进程自己
立刻抢下激活。macOS 依旧会激活它挑的应用，但那个应用来不及先把其他空间的窗口 order in，跟随规则也就
不会触发 —— 实测余量约 380ms。Dock 图标跟随因此保持原生、语义完整。

守护进程没有窗口也没有菜单栏，菜单栏仍归 macOS 挑的那个应用，视觉上没有任何变化；唯一的痕迹是空桌面上
敲键盘不会进到任何地方 —— 而它本来也无处可去。

**macOS 27 不需要这个守卫，也不会得到它。** 27 在无窗口落点会激活 Finder，而 Finder 拥有桌面、没有
其他空间的窗口可 order in，链条根本不会启动。守卫在 27+ 上被关闭 —— 在那里运行它只会把 Finder 挤掉，
而空桌面上 Finder 正是你想要的激活对象。

两个看起来可行但实际无效的变体（记录在案，免得再试）：在目标空间放一个真实窗口（确认窗口已驻留，依旧
会被拽走 —— 触发条件是"空"，不是"原因"），以及**在切换之前**抢激活（切换落地时会重新激活 macOS 挑的
应用，把之前的激活抹掉）。

## 疑难排查

**Ctrl+方向键或滑动没反应。** 看 `~/Library/Logs/noswoosh-pro.log`。最后一行是
`waiting for Accessibility permission` 说明守护进程还没拿到授权；授予后日志会出现
`Accessibility granted`，守护进程会自己重启。出现 `could not create swipe event tap` 也是同一件事 ——
tap 需要辅助功能权限，授权后的那次重启会修复它。

**辅助功能里的勾选不生效 / 勾不住。** 用"−"删掉条目，让守护进程重新弹一次授权提示，再允许。如果仍然不行：

```sh
launchctl kickstart -k gui/$(id -u)/xu.max.noswoosh-pro
```

**空间切换顺序不符合预期。** 关掉 系统设置 → 桌面与程序坞 里的"根据最近使用情况自动重新排列空间"。

## 已知限制

- **不支持 macOS 26.0–26.5**（Apple 在 26.6 修掉了底层 bug）。这些版本存在 WindowServer 竞态：
  零位移的合成切换会丢掉目标空间的窗口合成表面 —— 切换本身成功，但你可能落在一个窗口永远画不出来
  （只有壁纸）的空间上，直到有什么东西重新 order in 它们。完整调查（根因、所有尝试过的规避方案：
  替换事件形状、分阶段节奏、表面预热、落地后修复、直接调用 SkyLight 切换，以及每一种为何失败）
  见 [issue #1](https://github.com/mmathys/noswoosh/issues/1)。**解决办法是把 macOS 升级到 26.6 或更高。**
- **私有 API。** `SLSCopyManagedDisplaySpaces`、未公开的手势 `CGEventField`、macOS 27 的 IOHID 载荷
  布局都不受 Apple 支持且是逆向得到的 —— 任何一次系统更新都可能改变它们。真发生时的表现是切换静默失效；
  修法是适配手势载荷（26 → 27 已经强制过一次）。noswoosh 把每条路径都放在运行时版本判断之后，
  这样将来的失效可以定位到具体一条路径。
- **Apple Silicon 的一个坑。** 参考实现用 `FLT_TRUE_MIN` 作为手势进度；这个次正规浮点数在 Apple Silicon
  的事件管线里某个环节会被刷成零（符号丢失），导致每次切换都往同一个方向走。本实现用 `1e-4`，
  它既能存活又仍然视觉为零。两条系统路径都用它 —— macOS 27 路径在 1.7.0 之前用的是满位移（`±1.0`），
  方向正确但肉眼可见地滑动；1.7.1 起在 27 上也改成近乎为零。

## 卸载

```sh
brew uninstall --cask noswoosh-pro     # 从源码安装的用：./scripts/uninstall.sh
```

会停止守护进程、移除 LaunchAgent，并恢复 `setup` 关掉的系统 Ctrl+方向键快捷键。
辅助功能里的条目可以自行删除。

## 参与贡献

欢迎提 issue 和 PR。整个工具就是一个 Swift 文件（[`noswoosh.swift`](noswoosh.swift)），构建方式：

```sh
swiftc noswoosh.swift -O -o noswoosh-pro \
    -F /System/Library/PrivateFrameworks -framework SkyLight
./scripts/make-app-bundle.sh --out build     # 组装出 build/noswoosh-pro.app
```

发布流程：改高 `noswooshVersion` → 提交 → 推送 → 打 `vX.Y.Z` tag，**并手动触发一次 release workflow**
（本 fork 里 tag push 不会触发 CI，只打 tag 什么都不会构建）。workflow 会发布签名后的 app 与 CLI 压缩包；
Homebrew cask（版本号 + `noswoosh-pro-<version>.app.zip` 的 sha256）之后在
[KylehsuXu/homebrew-tap](https://github.com/KylehsuXu/homebrew-tap) 里手工更新，
因为自动更新 cask 的步骤以公证（notarization）为前提，本 fork 没有公证。

## 致谢

- **上游：[mmathys/noswoosh](https://github.com/mmathys/noswoosh)，作者
  [@mmathys](https://github.com/mmathys) —— 非常感谢。** 本 fork 能工作的每一部分都是他的成果：
  合成手势技巧、替换真实滑动的事件 tap、macOS 27 的 IOHID 载荷、macOS 27 的读写符号约定、
  空桌面 yank 守卫、安装脚本、发布流程以及这份文档。`noswoosh-pro` 只在其上增加了一个功能
  （应用激活抢占），其余完全跟随上游。
- 手势技巧：[jurplel/InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher)
  （`±FLT_TRUE_MIN` 进度技巧与三阶段手势）与 [gechr/WhichSpace](https://github.com/gechr/WhichSpace)。
- macOS 27 的 IOHID 载荷与滑动拦截思路：
  [joshuarli/iss](https://github.com/joshuarli/iss)（ISC 许可）。
- 强制前置（force-front）技巧：[koekeishiya/yabai](https://github.com/koekeishiya/yabai)。

## 许可

MIT —— 见 [LICENSE](LICENSE)。

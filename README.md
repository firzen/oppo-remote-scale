# OPPO 远控分辨率助手

OPPO 远控分辨率助手是一个 macOS 分辨率助手，适用于使用 O+ Connect（OPPO 互联）远控 Mac 的场景。

![O+ Connect 窗口旁的「手机友好」和「恢复」悬浮按钮，底部显示当前分辨率](docs/images/showcase.png)

<p align="center">macOS 实际界面 · 悬浮按钮跟随 O+ Connect 窗口</p>

![折叠屏展开后的 Mac 远控画面，底部显示远控工具条和电脑键盘](docs/images/foldable-remote-redacted.png)

<p align="center">外框参考 OPPO Find N6 / N5 · 屏幕内为脱敏后的实际远控截图</p>

![折叠屏手机半折 90°，上半屏显示 Mac 桌面，下半屏显示远控键盘](docs/images/foldable-remote-90.png)

<p align="center">90° 半折效果示意 · 上半屏显示 Mac 桌面，下半屏显示远控键盘</p>

## 下载与使用

1. 从 [GitHub Releases](https://github.com/firzen/oppo-remote-scale/releases/latest) 下载通用版 ZIP。
2. 解压并打开 `OPPO 远控分辨率助手.app`。应用支持 macOS 15 及更新版本，包含 Intel 和 Apple 芯片架构。
3. 在 O+ Connect 中开始远控。Mac 锁屏时保持原分辨率，确认解锁并进入桌面后才切换。在已测试的 Mac 上，手机友好分辨率为 1152 × 720。检测到断开后等待 3 秒。期间重新连入会保留当前档位，否则自动恢复记录的原分辨率。没有原分辨率记录且内屏仍处于手机友好档位时，恢复到系统默认分辨率。
4. 可通过 macOS 菜单栏的显示器图标手动选择「手机友好」或「恢复」。O+ Connect 窗口可见时，窗口旁也会显示相同按钮。

自动切换时，桌面上方会显示进度提示，完成后短暂显示系统读回的分辨率。

屏幕尺寸以 macOS 的实际回读结果为准。O+ Connect 当前会话的视频流可能继续使用连接建立时的采集尺寸。

发布包使用临时签名，尚未经过 Apple 公证。下载后的应用可能会被 Gatekeeper 拦截。

## 本地构建

需要 Xcode Command Line Tools。

```sh
./build.sh
```

构建结果位于 `build/OPPO 远控分辨率助手.app`。

## 远控自检

用手机连接一次，切换分辨率，再断开并重新连接。从仓库目录运行以下命令，查看最近两天的连接日志、抓屏启停和 O+ Connect 记录的输出尺寸。

```sh
"build/OPPO 远控分辨率助手.app/Contents/MacOS/RemoteScale" --remote-check
log show --last 1h --style compact --predicate 'process == "RemoteScale" AND eventMessage BEGINSWITH "RemoteScale "'
```

按时间对照助手日志中的 `switch-readback` 与抓屏日志中的 `UpdateCaptureParam`。抓屏日志显示 Mac 端记录的输出参数，手机上的实际画面以实机观察为准。

## 工作方式

OPPO 远控分辨率助手在本机读取 O+ Connect 的远控会话日志，通过 Core Graphics 调整主屏分辨率。切换前按显示器 UUID 保存原档位和目标档位。助手异常退出后，重新打开时会检查恢复记录。远控已断开且显示器仍处于目标档位时自动恢复，发现显示模式已另行改变时可手动恢复。运行时无需第三方依赖。自动切换依赖 O+ Connect 的日志格式，客户端更新后可能需要适配。

OPPO 远控分辨率助手是独立工具，与 OPPO 无隶属关系。

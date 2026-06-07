[English](README.md) | [中文](README_zh.md)

# PowerMonitor

PowerMonitor 是一款适用于 macOS 的硬件状态监控与风扇控制应用。

## 应用截图

<div align="center">
  <table>
    <tr>
      <td rowspan="2" valign="top">
        <img src="screenshots/fan_control.png" alt="风扇控制" width="350">
      </td>
      <td valign="top">
        <img src="screenshots/menu_bar.png" alt="菜单栏展示" width="350">
      </td>
    </tr>
    <tr>
      <td valign="bottom">
        <img src="screenshots/network_overlay.png" alt="网络悬浮窗" width="350">
      </td>
    </tr>
  </table>
</div>

## 安装与运行

由于编译好的 Release 应用程序没有使用付费的苹果开发者证书进行签名（使用的是 ad-hoc 本地签名），当您从互联网下载该应用后，macOS 的网关（Gatekeeper）机制可能会拦截该应用，并提示“App 已损坏，无法打开”。

要解决这个问题，您需要清除下载文件的隔离属性。将应用解压并拖入 `应用程序 (Applications)` 文件夹后，打开“终端（Terminal）”并执行以下命令：

```bash
sudo xattr -cr /Applications/PowerMonitor.app
```

执行完毕后，您就可以双击正常打开该应用了。

## 源码编译说明

如果您想自己通过 Xcode 编译源码，在打开 Xcode 工程之前，必须先手动编译 `PowerMonitorFanHelper` 二进制文件，它负责提供底层的风扇控制权限支持。

1. 打开终端，进入本项目的根目录。
2. 运行以下命令来编译 Fan Helper：

```bash
swiftc PowerMonitor/Resources/FanHelperSource.txt -o PowerMonitor/Resources/PowerMonitorFanHelper
```

3. 编译成功并确保生成了 `PowerMonitor/Resources/PowerMonitorFanHelper` 文件后，再在 Xcode 中打开 `PowerMonitor.xcodeproj`。
4. 像往常一样点击 Build and Run 即可。

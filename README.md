[English](README.md) | [中文](README_zh.md)

# PowerMonitor

PowerMonitor is a macOS application for monitoring power usage and controlling fans.

## Screenshots

<div align="center">
  <table>
    <tr>
      <td rowspan="2" valign="top">
        <img src="screenshots/fan_control.png" alt="Fan Control" width="350">
      </td>
      <td valign="top">
        <img src="screenshots/menu_bar.png" alt="Menu Bar" width="350">
      </td>
    </tr>
    <tr>
      <td valign="bottom">
        <img src="screenshots/network_overlay.png" alt="Network Overlay" width="350">
      </td>
    </tr>
  </table>
</div>

## Installation & Running

Since the provided releases are not signed with a paid Apple Developer certificate (they are ad-hoc signed), macOS Gatekeeper may mark the app as "damaged" and refuse to open it when you download it from the internet.

To resolve this, you need to clear the quarantine attribute. After extracting the app and moving it to your `Applications` folder, open your Terminal and run:

```bash
sudo xattr -cr /Applications/PowerMonitor.app
```

After running this command, you can double-click the application to launch it normally.

## Build Instructions

Before building the project in Xcode, you must compile the `PowerMonitorFanHelper` binary, which is responsible for the fan control capabilities.

1. Open your terminal and navigate to the root directory of this project.
2. Run the following command to compile the Fan Helper:

```bash
swiftc PowerMonitor/Resources/FanHelperSource.txt -o PowerMonitor/Resources/PowerMonitorFanHelper
```

3. Once the binary is compiled and placed in `PowerMonitor/Resources/`, you can open `PowerMonitor.xcodeproj` in Xcode.
4. Build and run the application as usual.

# Screen Manager for macOS

[简体中文](README.md) · [English](README_EN.md)

A macOS menu bar utility for finding processes that prevent the display or Mac from sleeping. Turn off the display immediately or on a timer, and keep the Mac awake while the display is off.

<p align="center">
  <img src="images/en.png" width="360" alt="Screen Manager English interface">
</p>

## Installation

Download and open the [Screen Manager DMG](build/屏幕管理.dmg). Drag **Screen Manager** onto the **Applications** shortcut in the mounted image. Open the app, then click its display icon in the menu bar.

Older releases and regular Actions artifacts are not Developer ID signed or notarized. If macOS says the app is damaged, right-click **Screen Manager** in Applications and choose **Open**. If it still won’t open, run `xattr -dr com.apple.quarantine "/Applications/屏幕管理.app"` in Terminal, then launch it again. Official GitHub Releases require the repository signing secrets; future releases will be notarized by Apple.

## Features

- **View wake sources:** Reads macOS power assertions every 8 seconds. Processes that prevent display sleep and system idle sleep are listed separately with their PIDs and assertion reasons.
- **Manage processes:** Select and quit multiple processes. Right-click a process to view its PID, assertion, executable path, and other details, or reveal it in Finder. Force quit requires confirmation.
- **Turn off the display:** Turn it off immediately or schedule it to turn off in 1 minute to 2 hours.
- **Keep the Mac awake:** Turn off the display while preventing idle sleep, either manually or after an automatic display-off event. Automatic sleep can be restored at any time.
- **Automatic display off:** Inactivity-based display off is disabled by default. When enabled, its idle timeout can be set from 10 to 86,400 seconds. The lock-screen display-off option is controlled by the inactivity auto-off switch.
- **Hide on app switch:** Clicking another app hides the main panel and process information windows.
- **English and Chinese UI:** The app follows the macOS preferred language by default. Use the globe menu in the upper-right corner to choose **Follow System**, **简体中文**, or **English**. The choice is saved and takes effect immediately. Unsupported system languages fall back to English.

## Notes

- Display off is requested with macOS `pmset displaysleepnow`. Keyboard, mouse, or trackpad activity can wake the display.
- Sleep prevention uses `NoIdleSleepAssertion`. It allows the display to sleep and prevents idle sleep, but macOS may still sleep the computer for forced reasons such as low battery or overheating.
- Lock-screen and inactivity-based display off work only while the app is running. Quitting the app ends its countdowns and releases its power assertions.
- The app reads power assertions registered with macOS. Wake sources caused by simulated input or display settings may not appear in the list.

## Community

Use the WeChat contact to share feedback and feature requests. The WeChat QR code：![微信二维码](images/微信二维码.jpg)

## Build from source

Building requires macOS 13 or later and Xcode Command Line Tools.

```sh
./build_app.sh
./build_dmg.sh
```

The app and DMG are created at `build/屏幕管理.app` and `build/屏幕管理.dmg`. The DMG script adds an **Applications** shortcut and verifies the disk image. The app icon is drawn by `Scripts/generate_app_icon.swift`; localization resources are in `Resources/en.lproj` and `Resources/zh-Hans.lproj`.

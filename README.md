# 雷鸟 / TCL 国内版电视（MT5879，Android 11）侧载 APK 实录

在雷鸟 65S78A（`tcl_mt5879_cn`，Android 11，2026-01 固件）上装 Jellyfin Android TV 客户端的完整过程。同平台的 TCL / 雷鸟国内机型应该也适用。

## TL;DR

- `adb install` / `pm install` 在这台机上**必然失败**，报 `INSTALL_FAILED_VERIFICATION_FAILURE`。拦截写死在系统 PackageInstaller 里，不受 `package_verifier_enable` 等开关影响。
- 绕法：借一个**已经装上**的第三方 App（这里用的是 FongMi 影视 `com.fongmi.android.tv`），让它通过自己的 FileProvider 调起系统安装器。这样走的是正常的“用户手动安装”流程，可以放行。
- 前提：电视已开 ADB 调试（网络调试 5555），电视上已有 FongMi 影视。

## 一键安装脚本

```bash
git clone https://github.com/no10playerzyf/tcl-ffalcon-tv-sideload.git
cd tcl-ffalcon-tv-sideload
./install.sh <电视IP> app.apk
# adb 不在 PATH 里的话：ADB=/path/to/adb ./install.sh <电视IP> app.apk
```

脚本会自动完成这些事：连电视、推送 APK、给 FongMi 文件访问权限、切前台、调起安装器、遥控点“继续”和“安装”、等装完、清理临时文件。macOS 和 Linux 都能用，需要 adb 和 curl。第一次连电视时，要在电视上点“允许 USB 调试”。

已在雷鸟 65S78A 上实测通过（2026-11-16，Jellyfin Android TV 0.20.0）。

## 为什么 adb 装不上（反编译 `/system/priv-app/PackageInstaller` 得出）

- `com.android.packageinstaller.verifier.VerifierReciver` 注册为安装校验器，交给 `StrategyService` 判断放不放行。策略从 TCL 在线配置 `InstallConfig` 下发。
- **PmStrategy**：带 `INSTALL_FROM_ADB`（flag 32）的安装一律拒。
- **ThridStrategy**：通过 packageinstaller 的显式安装，只放行三种来源：系统应用、白名单应用、应用自我更新。
- **LauncherStrategy**：拦第三方桌面，所以国内版换不了桌面。
- `/apex/com.tcl.tcore/javalib/tcl-service.jar` 里的 `OverseasAppConfig` 只往 `com.tpa.kb` 发广播，不负责拦截。
- 想用 shell 停掉校验组件也不行：`pm disable com.android.packageinstaller/...VerifierReciver` 会报 `SecurityException: Shell cannot change component state`。要彻底去掉只能 root。

## 走不通的路

| 尝试 | 结果 |
|---|---|
| `adb install` / `pm install` | VERIFICATION_FAILURE |
| `settings put global package_verifier_enable 0` / `verifier_verify_adb_installs 0` | 默认就是 0，没用 |
| shell 里 `am start` 安装 intent | `file://` 解析失败；`content://` 因 uid 2000 没有 REQUEST_INSTALL_PACKAGES 被拒 |
| 媒体中心打开 APK | 看不到 APK 文件 |
| 应用商店 `APPSTORE_INSTALL_APK` | 只认商店自己商品库里的应用 |

## 能用的方法

```bash
TV=<电视IP>:5555
adb connect $TV
adb -s $TV push app.apk /sdcard/Download/app.apk

# 1. 给 FongMi 文件访问权限（不给的话安装器报“解析包时出现问题”）
adb -s $TV shell appops set com.fongmi.android.tv MANAGE_EXTERNAL_STORAGE allow

# 2. 先把 FongMi 切到前台（后台启动 Activity 会被拦）
adb -s $TV shell monkey -p com.fongmi.android.tv -c android.intent.category.LAUNCHER 1

# 3. 调 FongMi 本地接口（端口 9978），让它打开 APK
curl -X POST http://<电视IP>:9978/action -d "do=file" \
  --data-urlencode "path=file://Download/app.apk"
```

电视上会弹出系统安装器：遥控器按 **右 → 确认** 点“继续”，再按 **右 → 确认** 点“安装”。装完 `installerPackageName` 显示的是 `com.android.packageinstaller`。

## 小技巧

- **adb 输入英文**：自带的搜狗 TV 输入法会把 `input text` 转成中文。先临时切到 TCL 自带的 SoftKeyboard，输完再切回去：
  ```bash
  IME=com.tcl.MultiScreenInteraction_TV/com.tcl.tcast.service.SoftKeyboard
  adb shell ime enable $IME; adb shell ime set $IME
  adb shell input text "http://192.168.x.x:8096"
  adb shell ime set com.sohu.inputmethod.sogou.tv/.SogouIME; adb shell ime disable $IME
  ```
- 在 bash heredoc 或循环里跑 `adb shell` 要加 `-n`（或 `</dev/null`），不然它会吞掉 stdin。
- 截图：`adb shell screencap -p /data/local/tmp/s.png && adb pull /data/local/tmp/s.png`

## 去广告

可以用 `pm disable-user --user 0 <pkg>` 停用预装应用（可逆，`pm enable` 恢复）。本机停用过的有 `com.tcl.bootadservice`（开机广告）、`com.tcl.wholenetsearch`、`com.tcl.tshop`、`com.tcl.gamecenter`、`com.tcl.usercenter`、`com.tcl.recognize.service`、`com.tcl.versionUpdateApp`、`com.snm.upgrade` 等。桌面推荐位是桌面自己画的，国内版又换不了桌面，所以去不掉。参考 [CleanYourTV](https://github.com/Gathin23/cleanyourtv)。

## 免责

仅供在自己的设备上学习使用。停掉系统升级会收不到官方补丁，风险自负。

# 雷鸟 / TCL 国内版电视（MT5879，Android 11）侧载 APK 实录

在雷鸟 65S78A（`tcl_mt5879_cn`，Android 11，2026-01 固件）上装 Jellyfin Android TV 客户端的完整过程。同平台的 TCL / 雷鸟国内机型应该也适用。

## TL;DR

- `adb install` / `pm install` 在这台机上**必然失败**，报 `INSTALL_FAILED_VERIFICATION_FAILURE`。拦截写死在系统 PackageInstaller 里，不受 `package_verifier_enable` 等开关影响。
- 绕法：借一个**已经装上**的第三方 App（这里用的是 FongMi 影视 `com.fongmi.android.tv`），让它通过自己的 FileProvider 调起系统安装器。这样走的是正常的“用户手动安装”流程，可以放行。
- 两种装法：**零前提的 `bootstrap.sh`**（直接驱动电视自带的“多屏互动”系统服务，电视上什么都不用先装）；或者电视上已有 FongMi 影视时用 `install.sh`。

## 已有 FongMi 影视时：install.sh

```bash
git clone https://github.com/no10playerzyf/tcl-ffalcon-tv-sideload.git
cd tcl-ffalcon-tv-sideload
./install.sh <电视IP> app.apk
# adb 不在 PATH 里的话：ADB=/path/to/adb ./install.sh <电视IP> app.apk
```

脚本会自动完成这些事：连电视、推送 APK、给 FongMi 文件访问权限、切前台、调起安装器、遥控点“继续”和“安装”、等装完、清理临时文件。macOS 和 Linux 都能用，需要 adb 和 curl。第一次连电视时，要在电视上点“允许 USB 调试”。

已在雷鸟 65S78A 上实测通过（2026-11-16，Jellyfin Android TV 0.20.0）。

## 零前提一键安装（推荐）：bootstrap.sh

`install.sh` 需要电视上**已经有**一个第三方 App（FongMi 影视）来调起安装器——
这就有个"先有鸡还是先有蛋"的问题：第一个 App 怎么装进去？

`bootstrap.sh` 解决了这个问题：**电视上什么都不用先装**，直接驱动电视自带的
系统服务"多屏互动"（T-Cast，`com.tcl.MultiScreenInteraction_TV`）完成安装。
用它把 FongMi 影视装进去之后，以后要批量装 APK 再用 `install.sh` 也行。

```bash
git clone https://github.com/no10playerzyf/tcl-ffalcon-tv-sideload.git
cd tcl-ffalcon-tv-sideload
./bootstrap.sh <电视IP> app.apk
# adb 不在 PATH 里：ADB=/path/to/adb ./bootstrap.sh <电视IP> app.apk
```

脚本会：推算本机 IP → 起一个临时 HTTP 服务把 APK 对外提供 → 连电视的
6553 端口发安装指令 → 电视自己把 APK 下载下来装上。电视上会弹一个
"X 正在发起应用推送，同意后将接收应用并进行安装"的框：有 adb 时脚本自动点
「同意」并校验结果；没有 adb 就按提示用遥控器 **右键 → 确认** 手动点一下即可。

- **依赖**：控制机要有 `python3`（收发指令 + 临时 HTTP 服务，都是标准库）。
  `adb` **可选**，只用来自动点「同意」和校验，手动确认就完全不需要。
- **前提**：电视和控制机在同一局域网；电视的"多屏互动"服务在运行（出厂自带、默认开）。
  连 6553 发指令**不需要** adb 调试；只有想让脚本自动点「同意」才需要 adb。
- 已在雷鸟 65S78A 上实测通过（2026-11-16，装 / 重装 Jellyfin 0.20.0，
  `lastUpdateTime` 每次都会刷新，`installerPackageName=com.tcl.MultiScreenInteraction_TV`）。

### 只装 FongMi 影视（之后好用 install.sh）

```bash
./bootstrap.sh <电视IP> fongmi.apk     # 先把影视装进去
./install.sh  <电视IP> other-app.apk   # 以后批量装别的 APK
```

## 原理：多屏互动的"安装本地 APK"指令（反编译 nscreen.apk 得出）

手机端的 TCL/雷鸟投屏遥控 App 和电视端的"多屏互动"之间，走的是 TCast 私有协议。
电视端在 **TCP 6553** 上做服务端（`bf/g.java` 里 `ServerSocket.bind(ip, 6553)`）。

- **分帧**：每条消息 = 4 字节大端长度 + UTF-8 负载（`DataOutputStream.writeInt(len)`
  后紧跟 `write(bytes)`，见 `bf/d.java`）。
- **握手（第一条消息必须是）**：`159>>任意>>加密模式`（cmd 159 = `HANDLE_CHANGE`）。
  第三段是加密模式：`0` = 明文，`1` = AES。只要第一条声明 `0`，后面全部明文，
  不用加密、不用配对、不用鉴权。（AES 用的是写死的 `AES/CBC/PKCS5Padding`，
  key=`tnscreentnscreen`，固定 IV——但声明明文就完全用不上。）
- **安装指令**：cmd 223 = `MANAGE_APP`，字段用 `>>` 连接：
  ```
  223>>INSTALL>>包名>>显示名>>http://<本机IP>:<端口>/app.apk>>2
  ```
  末段 `2` = `appSource=LOCAL`。电视收到后会**自己**从这个 HTTP URL 下载 APK，
  再走它自己的 `PackageInstaller` 安装。因为发起方是系统应用，**不触发国内版
  对 adb 安装的 `INSTALL_FAILED_VERIFICATION_FAILURE` 拦截**。
- **确认框**：本地来源（appSource=2）会在电视上弹一个确认框（`te/c.java`），
  电视回一条 `223>>INSTALL>>…>>confirm_pending>>null`。遥控器 **右键** 把焦点
  从「拒绝」移到「同意」，**确认键** 点下去（adb 对应 `keyevent 22` 再 `keyevent 23`）。
  点完电视静默下载并安装，装完回报 `code=0`。
- 会话要**保持住**：确认框和下载都挂在这条 TCP 会话上，断开框就消失，
  所以脚本会每 7 秒发一个 `150>>1` 心跳保活（电视读超时约 20 秒）。

> 安全提醒：任何在同一局域网内的设备都能连 6553 发这条指令，弹框按「同意」
> 就会装。平时家里网络可信，问题不大；但别在不可信的网络（如公共 Wi-Fi）
> 上把电视暴露出去。

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

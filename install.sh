#!/usr/bin/env bash
# 雷鸟/TCL 国内版电视一键侧载 APK（绕过 adb 安装拦截）
# 用法: ./install.sh <电视IP> <app.apk>
# 前提: 电视已开网络 ADB 调试(5555)，且已装 FongMi 影视 (com.fongmi.android.tv)
set -euo pipefail

TV_IP="${1:-}"; APK="${2:-}"
[[ -z "$TV_IP" || -z "$APK" ]] && { echo "用法: $0 <电视IP> <app.apk>"; exit 1; }
[[ -f "$APK" ]] || { echo "找不到文件: $APK"; exit 1; }
ADB="${ADB:-adb}"
command -v "$ADB" >/dev/null || { echo "没找到 adb，请先安装 Android platform-tools，或用 ADB=/path/to/adb 指定"; exit 1; }
TV="$TV_IP:5555"
FM=com.fongmi.android.tv
NAME="sideload_$(date +%s).apk"
a() { "$ADB" -s "$TV" "$@" </dev/null; }

echo "==> 连接电视 $TV"
"$ADB" connect "$TV" >/dev/null
a get-state >/dev/null 2>&1 || { echo "连不上电视：确认已开 ADB 调试，并在电视上点了“允许”"; exit 1; }

a shell pm path $FM >/dev/null 2>&1 || { echo "电视上没有 FongMi 影视 ($FM)，这个方法需要它"; exit 1; }

PKG=""
if command -v aapt >/dev/null; then PKG=$(aapt dump badging "$APK" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p"); fi

BEFORE=$(a shell pm list packages | sort)

echo "==> 推送 APK"
a push "$APK" "/sdcard/Download/$NAME" >/dev/null 2>&1

echo "==> 给影视文件访问权限并切到前台"
a shell appops set $FM MANAGE_EXTERNAL_STORAGE allow
a shell monkey -p $FM -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 4

echo "==> 通过影视调起系统安装器"
curl -fsS -X POST "http://$TV_IP:9978/action" -d "do=file" \
  --data-urlencode "path=file://Download/$NAME" >/dev/null \
  || { echo "影视本地接口 :9978 没响应，打开一次影视再试"; exit 1; }
sleep 4

echo "==> 自动点“继续”和“安装”"
a shell input keyevent 22; a shell input keyevent 23; sleep 3
a shell input keyevent 22; a shell input keyevent 23

echo "==> 等待安装完成"
for i in $(seq 1 60); do
  if [[ -n "$PKG" ]] && a shell pm list packages "$PKG" | grep -qx "package:$PKG"; then
    a shell dumpsys package "$PKG" | grep -m1 versionName | sed 's/^ */    /'
    break
  fi
  if [[ -z "$PKG" ]]; then
    NEW=$(comm -13 <(echo "$BEFORE") <(a shell pm list packages | sort) | sed 's/^package://' | tr -d '\r' | head -1)
    [[ -n "$NEW" ]] && { PKG="$NEW"; continue; }
    [[ $i -ge 20 ]] && break
  fi
  sleep 2
done

a shell input keyevent 4   # 关掉“是否立即体验”弹窗
a shell rm -f "/sdcard/Download/$NAME"
if [[ -n "$PKG" ]]; then
  a shell pm list packages "$PKG" | grep -qx "package:$PKG" && echo "✅ 安装完成: $PKG" || echo "⚠️ 没检测到 $PKG，看一下电视屏幕"
else
  echo "✅ 已发起安装（没装 aapt，无法自动确认包名），看一下电视屏幕"
fi

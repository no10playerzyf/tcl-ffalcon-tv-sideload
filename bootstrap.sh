#!/usr/bin/env bash
# 零前提侧载：直接驱动电视自带的"多屏互动"系统服务安装 APK
# -----------------------------------------------------------------------------
# 跟 install.sh 不同，这个脚本【不需要电视上事先装任何第三方 App】。
# 原理：com.tcl.MultiScreenInteraction_TV（T-Cast，系统应用）在 TCP 6553 上
#      监听手机投屏/遥控 App 的指令。它支持一条"安装本地 APK"的指令
#      (cmd 223 / MANAGE_APP, appState=INSTALL, appSource=2=LOCAL)：
#      电视会自己从你给的 HTTP URL 把 APK 下载下来，再走它自己的
#      PackageInstaller 安装——因为发起方是系统应用，不触发国内版的 adb 安装拦截。
#      电视上只会弹一个"X 正在发起应用推送，同意后将接收应用并进行安装"的确认框。
#
# 用法: ./bootstrap.sh <电视IP> <app.apk>
# 依赖: python3（必须，收发指令 + 临时 HTTP 服务）
#       adb  （可选，仅用来自动点「同意」和校验结果；没有就手动按遥控器）
#
# 已在雷鸟 65S78A (tcl_mt5879_cn, Android 11) 实测通过。
set -euo pipefail

TV_IP="${1:-}"; APK="${2:-}"
[[ -z "$TV_IP" || -z "$APK" ]] && { echo "用法: $0 <电视IP> <app.apk>"; exit 1; }
[[ -f "$APK" ]] || { echo "找不到文件: $APK"; exit 1; }
command -v python3 >/dev/null || { echo "需要 python3"; exit 1; }

PORT="${PORT:-$(( (RANDOM % 20000) + 20000 ))}"
ADB="${ADB:-adb}"
HAVE_ADB=0
if command -v "$ADB" >/dev/null 2>&1; then HAVE_ADB=1; fi

# 控制机在"能被电视访问到"的那张网卡上的 IP（跟电视连同一个 UDP 目标推算）
HOST_IP="$(python3 - "$TV_IP" <<'PY'
import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
try:
    s.connect((sys.argv[1],9)); print(s.getsockname()[0])
finally:
    s.close()
PY
)"
[[ -z "$HOST_IP" ]] && { echo "无法确定本机 IP"; exit 1; }

# 解析包名（有 aapt 更准，用于结果校验；没有也不影响安装）
PKG=""
if command -v aapt >/dev/null 2>&1; then
  PKG=$(aapt dump badging "$APK" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
fi
APPNAME="$(basename "$APK" .apk)"

# 临时 HTTP 根目录，把 APK 放进去对外提供
WORK="$(mktemp -d)"
cp -f "$APK" "$WORK/app.apk"
URL="http://$HOST_IP:$PORT/app.apk"

# 没有 aapt 时，用内置的 AXML 解析器从 APK 里读包名（用于结果校验，安装本身不依赖它）
if [[ -z "$PKG" ]]; then
  cat > "$WORK/axml.py" <<'AXML'
import sys, zipfile, struct
def apk_package(path):
    with zipfile.ZipFile(path) as z:
        data = z.read('AndroidManifest.xml')
    strings=[]; pos=8
    while pos < len(data):
        ctype, hsize, csize = struct.unpack('<HHI', data[pos:pos+8])
        if csize<=0: break
        if ctype == 0x0001:
            sc = data[pos:pos+csize]
            scount = struct.unpack('<I', sc[8:12])[0]
            flags  = struct.unpack('<I', sc[16:20])[0]
            sstart = struct.unpack('<I', sc[20:24])[0]
            isUTF8 = (flags & 0x100)!=0
            offs = struct.unpack('<%dI'%scount, sc[28:28+4*scount])
            for o in offs:
                p = sstart+o
                if isUTF8:
                    n=sc[p]; p+=1
                    if n&0x80: n=((n&0x7f)<<8)|sc[p]; p+=1
                    blen=sc[p]; p+=1
                    if blen&0x80: blen=((blen&0x7f)<<8)|sc[p]; p+=1
                    strings.append(sc[p:p+blen].decode('utf-8','replace'))
                else:
                    n=sc[p]|(sc[p+1]<<8); p+=2
                    if n&0x8000: n=((n&0x7fff)<<16)|(sc[p]|(sc[p+1]<<8)); p+=2
                    strings.append(sc[p:p+n*2].decode('utf-16-le','replace'))
            break
        pos += csize
    pos=8
    while pos < len(data):
        ctype, hsize, csize = struct.unpack('<HHI', data[pos:pos+8])
        if csize<=0: break
        if ctype == 0x0102:
            body = data[pos:pos+csize]
            name = struct.unpack('<i', body[20:24])[0]
            if 0<=name<len(strings) and strings[name]=='manifest':
                attrStart = struct.unpack('<H', body[24:26])[0]
                attrCount = struct.unpack('<H', body[28:30])[0]
                ab = 16 + attrStart
                for i in range(attrCount):
                    a = body[ab+i*20: ab+i*20+20]
                    a_name = struct.unpack('<i', a[4:8])[0]
                    a_raw  = struct.unpack('<i', a[8:12])[0]
                    if 0<=a_name<len(strings) and strings[a_name]=='package' and 0<=a_raw<len(strings):
                        return strings[a_raw]
        pos += csize
    return None
try: print(apk_package(sys.argv[1]) or "")
except Exception: print("")
AXML
  PKG=$(python3 "$WORK/axml.py" "$APK" 2>/dev/null)
fi
[[ -n "$PKG" ]] && echo "==> 包名: $PKG"

HTTP_PID=""; SEND_PID=""
cleanup() {
  [[ -n "$SEND_PID" ]] && kill "$SEND_PID" 2>/dev/null || true
  [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> 本机 IP: $HOST_IP  端口: $PORT"
echo "==> 启动临时 HTTP 服务，提供: $URL"
( cd "$WORK" && exec python3 -m http.server "$PORT" --bind 0.0.0.0 ) >/dev/null 2>&1 &
HTTP_PID=$!
disown $HTTP_PID 2>/dev/null || true
sleep 1

# TCast 发送器：连 6553，先发握手(159，声明不加密=明文)，再发安装指令(223)，
# 之后用心跳把会话保持住（确认框和下载都在这条会话上，断开会话弹框就消失）。
cat > "$WORK/send.py" <<'PY'
import socket,struct,sys,time,threading
tv,url,pkg,name,keep=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],int(sys.argv[5])
def frame(s):
    b=s.encode('utf-8'); return struct.pack('>i',len(b))+b
def reader(sock):
    sock.settimeout(1.0); buf=b''
    while True:
        try:
            d=sock.recv(8192)
            if not d: return
            buf+=d
            while len(buf)>=4:
                n=struct.unpack('>i',buf[:4])[0]
                if n<=0 or len(buf)<4+n: break
                p=buf[4:4+n]; buf=buf[4+n:]
                t=p.decode('utf-8','replace')
                if 'INSTALL' in t: print('[TV]',t[:160],flush=True)
        except socket.timeout: continue
        except Exception: return
s=socket.create_connection((tv,6553),timeout=5)
threading.Thread(target=reader,args=(s,),daemon=True).start()
s.sendall(frame("159>>0>>0")); time.sleep(0.6)          # 握手：明文模式
s.sendall(frame(">>".join(["223","INSTALL",pkg,name,url,"2"])))  # 本地 APK 安装
t0=time.time()
while time.time()-t0<keep:
    time.sleep(7)
    try: s.sendall(frame("150>>1"))                      # 心跳，保活会话
    except Exception: break
s.close()
PY

BEFORE_LUT=""
if [[ "$HAVE_ADB" == 1 ]]; then
  "$ADB" connect "$TV_IP:5555" >/dev/null 2>&1 || true
  if "$ADB" -s "$TV_IP:5555" get-state >/dev/null 2>&1; then
    "$ADB" -s "$TV_IP:5555" logcat -c >/dev/null 2>&1 || true
    [[ -n "$PKG" ]] && BEFORE_LUT=$("$ADB" -s "$TV_IP:5555" shell dumpsys package "$PKG" </dev/null 2>/dev/null | sed -n 's/.*lastUpdateTime=//p' | head -1)
  else
    HAVE_ADB=0
  fi
fi

echo "==> 发送安装指令到电视 $TV_IP:6553"
python3 "$WORK/send.py" "$TV_IP" "$URL" "${PKG:-$APPNAME}" "$APPNAME" 90 &
SEND_PID=$!
disown $SEND_PID 2>/dev/null || true

if [[ "$HAVE_ADB" == 1 ]]; then
  echo "==> 等待电视弹出确认框，自动点「同意」"
  OK=0
  for i in $(seq 1 30); do
    if "$ADB" -s "$TV_IP:5555" logcat -d </dev/null 2>/dev/null | grep -qE "confirm_pending|push typeDIALOGte\.c"; then
      sleep 1
      "$ADB" -s "$TV_IP:5555" shell input keyevent 22 </dev/null   # 右：焦点移到「同意」
      sleep 0.4
      "$ADB" -s "$TV_IP:5555" shell input keyevent 23 </dev/null   # 确认
      OK=1; break
    fi
    sleep 1
  done
  [[ "$OK" == 0 ]] && echo "   （没抓到确认框，若电视上有弹框请手动按 右→确认 点「同意」）"

  echo "==> 等待安装完成"
  for i in $(seq 1 60); do
    if [[ -n "$PKG" ]]; then
      NOW=$("$ADB" -s "$TV_IP:5555" shell dumpsys package "$PKG" </dev/null 2>/dev/null | sed -n 's/.*lastUpdateTime=//p' | head -1)
      if [[ -n "$NOW" && "$NOW" != "$BEFORE_LUT" ]]; then
        VER=$("$ADB" -s "$TV_IP:5555" shell dumpsys package "$PKG" </dev/null 2>/dev/null | sed -n 's/.*versionName=//p' | head -1)
        echo "✅ 安装完成: $PKG  版本 $VER  (lastUpdateTime=$NOW)"
        exit 0
      fi
    fi
    if "$ADB" -s "$TV_IP:5555" logcat -d </dev/null 2>/dev/null | grep -qE "onReceive: code=0|PACKAGE_ADDED.*${PKG:-org}"; then
      echo "✅ 电视回报安装成功"
      exit 0
    fi
    sleep 2
  done
  echo "⚠️ 没在限定时间内确认安装结果，看一下电视屏幕"
else
  echo "==> 没有可用的 adb。请在电视屏幕上，对弹出的「同意」框按 遥控器右键 → 确认。"
  echo "    （确认后电视会自动从 $URL 下载并安装；本脚本会保持服务 ~90 秒）"
  sleep 92   # 等 send.py 的 90 秒保活跑完（期间请在电视上确认）
  echo "完成。请在电视上确认 APP 是否已出现。"
fi

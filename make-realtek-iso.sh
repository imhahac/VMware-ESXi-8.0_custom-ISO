#!/bin/bash
# 將 Realtek Network Driver Fling (if-re) 注入 ESXi 8.0U3e 免費版 ISO
# 方法參考 William Lam：在 boot.cfg 的 modules 加入 ifre.v00，讓安裝程式能偵測 RTL8111/8125/8126/8127
# 用法: ./make-realtek-iso.sh [VMware-Re-Driver_*.zip]
set -euo pipefail
cd "$(dirname "$0")"

SRC_ISO="VMware-VMvisor-Installer-8.0U3e-24677879.x86_64.iso"
OUT_ISO="VMware-VMvisor-Installer-8.0U3e-24677879-Realtek.x86_64.iso"
DRIVER_ZIP="${1:-$(ls VMware-Re-Driver_*.zip 2>/dev/null | head -1 || true)}"

command -v xorriso >/dev/null || { echo "請先安裝 xorriso: brew install xorriso"; exit 1; }
[ -f "$SRC_ISO" ]    || { echo "找不到 $SRC_ISO"; exit 1; }
[ -f "$DRIVER_ZIP" ] || { echo "找不到 Realtek 驅動 zip (VMware-Re-Driver_*.zip)"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. 從 offline bundle 取出 if-re VIB，再用 ar 解出 payload
unzip -q "$DRIVER_ZIP" -d "$WORK/zip"
VIB="$(find "$WORK/zip" -name '*if-re*.vib' | head -1)"
[ -n "$VIB" ] || { echo "zip 內找不到 if-re VIB"; exit 1; }
echo "VIB: $(basename "$VIB")"
mkdir "$WORK/vib"
# VIB 是 ar 封裝；macOS 的 BSD ar 不可靠，改用 Python 解析
python3 - "$VIB" "$WORK/vib" <<'PY'
import os, sys
data = open(sys.argv[1], 'rb').read()
assert data[:8] == b'!<arch>\n', 'not an ar archive'
pos = 8
while pos + 60 <= len(data):
    hdr = data[pos:pos + 60]
    name = hdr[:16].decode().strip().rstrip('/')
    size = int(hdr[48:58].decode().strip())
    pos += 60
    body = data[pos:pos + size]
    if name.startswith('#1/'):  # BSD 長檔名
        n = int(name[3:]); name, body = body[:n].decode().rstrip('\0'), body[n:]
    if name and not name.startswith('__.SYMDEF'):
        open(os.path.join(sys.argv[2], name), 'wb').write(body)
    pos += size + (size & 1)
PY
PAYLOAD="$WORK/vib/ifre"
[ -f "$PAYLOAD" ] || { echo "VIB 內找不到 ifre payload，內容: $(ls "$WORK/vib")"; exit 1; }
cp "$PAYLOAD" "$WORK/IFRE.V00"

# 2. 修改 boot.cfg：modules 行尾加入 /ifre.v00
xorriso -osirrox on -indev "$SRC_ISO" -extract /BOOT.CFG "$WORK/BOOT.CFG" >/dev/null 2>&1
chmod u+w "$WORK/BOOT.CFG"
if ! grep -q 'ifre.v00' "$WORK/BOOT.CFG"; then
  sed -i.bak -E '/^modules=/ s|[[:space:]]*$| --- /ifre.v00|' "$WORK/BOOT.CFG"
fi
grep -q -- '--- /ifre.v00' "$WORK/BOOT.CFG" || { echo "boot.cfg 修改失敗"; exit 1; }

# 避免空間浪費：OSDATA (VMFS-L) 預設最大 128GB，限制為 8GB，其餘空間給 datastore
# 可用環境變數調整，例如 OSDATA_MB=16384 ./make-realtek-iso.sh
OSDATA_MB="${OSDATA_MB:-8192}"
sed -i.bak -E "/^kernelopt=/ { s/[[:space:]]*autoPartitionOSDataSize=[0-9]+//; s/[[:space:]]*\$/ autoPartitionOSDataSize=${OSDATA_MB}/; }" "$WORK/BOOT.CFG"
grep -q "^kernelopt=.*autoPartitionOSDataSize=${OSDATA_MB}" "$WORK/BOOT.CFG" || { echo "kernelopt 修改失敗"; exit 1; }

# 3. 重新封裝 ISO（保留原本的 BIOS + UEFI El Torito 開機設定）
rm -f "$OUT_ISO"
xorriso -indev "$SRC_ISO" -outdev "$OUT_ISO" \
  -map "$WORK/IFRE.V00" /IFRE.V00 \
  -map "$WORK/BOOT.CFG" /BOOT.CFG \
  -map "$WORK/BOOT.CFG" /EFI/BOOT/BOOT.CFG \
  -boot_image any replay \
  -volume_date uuid "$(date -u +%Y%m%d%H%M%S00)" 2>&1 | grep -E 'Writing|FAILURE|SORRY' || true

echo
echo "完成: $(pwd)/$OUT_ISO"
xorriso -indev "$OUT_ISO" -report_el_torito plain 2>/dev/null | grep 'img path'

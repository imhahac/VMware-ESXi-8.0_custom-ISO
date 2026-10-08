# ESXi 8.0U3e on HuananZhi X99-F8D（Realtek RTL8111H）

在 **HuananZhi X99-F8D** 主機板上安裝免費版 **VMware ESXi 8.0 Update 3e**，並解決板載 Realtek 網卡的兩個問題：

1. **安裝時找不到網卡**：ESXi 8 內建驅動不支援 RTL8111H。本 repo 的腳本會把 Broadcom 官方的 Realtek Fling 驅動注入官方 ISO。
2. **裝好後網路極慢**：延遲固定約 1 秒，上傳只有約 140 KB/s。原因是驅動預設的 INTx 中斷在這片主機板上無法運作，改用 MSI 中斷即可解決（[第 5 節](#5-網路極慢延遲約-1-秒改用-msi-中斷)）。

> 本 repo 不包含任何 VMware / Broadcom 的檔案。ISO 與驅動請自行從 Broadcom Support Portal 下載。

---

## 目錄

- [環境](#環境)
- [1. 下載所需檔案](#1-下載所需檔案)
- [2. 產生自製 ISO](#2-產生自製-iso)
- [3. 用 Rufus 製作 USB 並安裝](#3-用-rufus-製作-usb-並安裝)
- [4. 安裝完成後：保留驅動](#4-安裝完成後保留驅動)
- [5. 網路極慢、延遲約 1 秒：改用 MSI 中斷](#5-網路極慢延遲約-1-秒改用-msi-中斷)
- [6. 傳送 ISO 到 datastore](#6-傳送-iso-到-datastore)
- [7. 疑難排解](#7-疑難排解)
- [技術細節](#技術細節)
- [參考資料](#參考資料)

---

## 環境

| 項目 | 內容 |
|---|---|
| 主機板 | HuananZhi X99-F8D（雙 LGA2011-3） |
| 網卡 | 板載 2 × Realtek RTL8111H（PCI ID `10ec:8168`） |
| Hypervisor | VMware ESXi 8.0U3e Free（Build 24677879） |
| 驅動 | Realtek Network Driver for ESXi Fling `1.101.01-5vmw.800.1.0.20613240` |
| 製作環境 | macOS（Apple Silicon 測試過），Linux 應該也可以 |

---

## 1. 下載所需檔案

需要登入 [Broadcom Support Portal](https://support.broadcom.com/)（免費註冊）。

| 檔案 | 位置 |
|---|---|
| `VMware-VMvisor-Installer-8.0U3e-24677879.x86_64.iso` | Free Downloads → 搜尋 **VMware vSphere Hypervisor** |
| `VMware-Re-Driver_1.101.01-5vmw.800.1.0.20613240.zip` | [Free Downloads → Flings](https://support.broadcom.com/group/ecx/productdownloads?subfamily=Flings&freeDownloads=true) → 搜尋關鍵字 **`Realtek`** |

> 在 Flings 頁面用完整檔名搜尋會顯示 *No data found*，請改搜 `Realtek`。
>
> 免費版只提供 ISO，**沒有 offline depot (.zip)**，所以不能用 PowerCLI Image Builder 製作自製 ISO，才改用本 repo 的做法。

下載後確認 ISO 的 SHA256：

```text
9782c96ffd01cc56da17ec31573da69f4cba2f9402e67c8b55d05d9472c7376a  VMware-VMvisor-Installer-8.0U3e-24677879.x86_64.iso
```

---

## 2. 產生自製 ISO

把上面兩個檔案放到和 `make-realtek-iso.sh` 同一個資料夾，然後執行：

```bash
# macOS
brew install xorriso
# Debian / Ubuntu：sudo apt install xorriso python3 unzip

./make-realtek-iso.sh
```

輸出檔：`VMware-VMvisor-Installer-8.0U3e-24677879-Realtek.x86_64.iso`

### 腳本做了什麼

| 修改 | 說明 |
|---|---|
| 新增 `/IFRE.V00` | 從 Fling 的 VIB 取出驅動 payload（`ifre`），內容與官方 VIB 逐位元組相同 |
| `BOOT.CFG` 的 `modules=` 結尾加上 `--- /ifre.v00` | 讓安裝程式開機時載入 Realtek 驅動。BIOS 用的 `/BOOT.CFG` 和 UEFI 用的 `/EFI/BOOT/BOOT.CFG` 都會修改 |
| `BOOT.CFG` 的 `kernelopt=` 加上 `autoPartitionOSDataSize=8192` | 把 OSDATA（VMFS-L）從預設最大 128GB 限制為 8GB，其餘空間自動變成 datastore |
| ISO 內部日期 | 更新為製作當下的時間 |

其他檔案完全不動，BIOS 與 UEFI 兩種開機方式都保留。

要調整 OSDATA 大小（例如會用到 vSAN，或想保留較多 log 空間）：

```bash
OSDATA_MB=16384 ./make-realtek-iso.sh
```

| 安裝硬碟 | 預設：系統占用 / 可用 datastore | `autoPartitionOSDataSize=8192` |
|---|---|---|
| 128GB | 約 128GB / 幾乎 0 | 約 12GB / 約 115GB |
| 256GB | 約 132GB / 約 120GB | 約 12GB / 約 240GB |
| 512GB | 約 132GB / 約 370GB | 約 12GB / 約 495GB |

> 這個設定只在**全新安裝**時有效。已經用預設方式安裝的系統，只能重新安裝才能改。

### 驗證輸出的 ISO（選用）

```bash
xorriso -osirrox on -indev VMware-VMvisor-Installer-8.0U3e-24677879-Realtek.x86_64.iso \
  -extract /EFI/BOOT/BOOT.CFG /tmp/boot.cfg >/dev/null 2>&1
grep -E "^kernelopt=" /tmp/boot.cfg            # 應包含 autoPartitionOSDataSize=8192
grep -o "imgpayld.tgz --- /ifre.v00" /tmp/boot.cfg
```

---

## 3. 用 Rufus 製作 USB 並安裝

1. 在 Rufus 選擇自製 ISO。
2. 分割配置選 **GPT**，目標系統選 **UEFI**。
3. 如果 Rufus 問要不要更新 `menu.c32`，選 **Yes**。
4. BIOS 裡確認 **Onboard LAN** 已啟用，從 USB 開機。
5. 照常安裝。這次安裝程式會偵測到 RTL8111H 網卡。

---

## 4. 安裝完成後：保留驅動

> ⚠️ **安裝完成畫面出現時，先不要按 Enter 重開機。**

注入 ISO 的驅動只有「安裝程式」會載入，裝好的系統裡並沒有這個驅動。重開機前要先把它複製到系統的開機分割區：

1. 按 **ALT+F1** 進入 console，帳號 `root`，密碼直接按 Enter（空白）。
2. 執行：

   ```bash
   cp /tardisks/ifre.v00 /vmfs/volumes/BOOTBANK1/ && \
   cp /tardisks/ifre.v00 /vmfs/volumes/BOOTBANK2/ && \
   sed -i '/^modules=/ s|$| --- ifre.v00|' /vmfs/volumes/BOOTBANK1/boot.cfg /vmfs/volumes/BOOTBANK2/boot.cfg
   ```

3. 按 **ALT+F2** 回到安裝畫面，按 Enter 重開機。

### 正式安裝驅動（強烈建議）

上面的做法是暫時的。ESXi 一旦升級或打 patch，`boot.cfg` 會重新產生，驅動就會不見，主機也會失去網路。開機有網路後，把驅動 zip 上傳到 datastore，再正式安裝：

```bash
esxcli software component apply -d /vmfs/volumes/datastore1/VMware-Re-Driver_1.101.01-5vmw.800.1.0.20613240.zip
reboot
```

確認：

```bash
esxcli software component list | grep -i re-driver
# VMware-Re-Driver   VMware Realtek Network Driver for ESXi   1.101.01-5vmw.800.1.0.20613240 ...
```

> 重開機後如果沒有網路：開機畫面出現時按 **Shift+R** 進入 Recovery Mode，回到前一個 bootbank。

---

## 5. 網路極慢、延遲約 1 秒：改用 MSI 中斷

### 症狀

- Host Client 上傳卡在 0%；SFTP 只有約 140 KB/s。
- 從 ESXi ping **同網段的閘道**，延遲固定在約 1000 ms，或在 0～1000 ms 之間均勻分布。
- `vmkernel.log` 每隔剛好約 1 秒出現一批：

  ```text
  if_re: _re_rxeof:8825: 0000040000: [0][653] RES bit set, opts1=0x342bc06f
  WARNING: if_re: _re_rxeof:8890: 0000040000: dropped packet: 653
  ```

- 兩個網孔註冊在同一個中斷，而且 `trigger: 0`：

  ```text
  if_re: re_alloc_intr: 0000040000: registered interrupt cookie 19, trigger: 0
  if_re: re_alloc_intr: 0000050000: registered interrupt cookie 19, trigger: 0
  ```

### 原因

- 這個 Fling 驅動預設 `msi_disable=1`、`msix_disable=1`，**只使用傳統 INTx 中斷**。
- 在 X99-F8D 上，INTx 中斷完全送不到系統。
- 驅動有一個保底機制：`re_tick()` 每秒執行一次，在 `re_poll_intr=1`（預設值）時主動呼叫一次中斷處理函式。所以網路還能用，但每個封包最多要等 1 秒才會被處理；這段時間內封包太多，接收緩衝區就會溢出、掉包。

### 修正

```bash
esxcli system module parameters set -m if_re -p "msi_disable=0"
reboot
```

### 修正結果

| | 修正前（INTx） | 修正後（MSI） |
|---|---|---|
| ping 閘道 | 平均約 600 ms，最高約 1000 ms | **0.27～0.36 ms** |
| 接收錯誤率 | 約 2.5% | 約 0.1% |
| 中斷 | 兩個網孔共用 cookie，`trigger: 0` | 各自獨立的 cookie，`trigger: 1` |
| 實際傳輸 | 約 140 KB/s，經常卡在 0% | ESXi 直接下載 4GB ISO 正常完成 |

確認設定：

```bash
esxcli system module parameters list -m if_re | grep msi_disable     # 應為 0
grep if_re /var/log/vmkernel.log | grep cookie | tail -2               # trigger: 1
ping -c 5 <GATEWAY_IP>                                                 # 應小於 1 ms
```

> 參數會寫入 ESXi 的系統設定，重開機和升級 ESXi 之後都會保留。但如果**重新安裝 ESXi** 或**移除後重裝驅動**，需要再設定一次。

### 試過但無效的方法

| 嘗試 | 結果 |
|---|---|
| `msix_disable=1` | 無效（預設值本來就是 1） |
| `iovDisableIR=TRUE`（停用 IOMMU 中斷重新導向） | 無效，已改回 `FALSE` |
| `msi_disable=1 msix_disable=1`（強制 INTx） | 無效（就是預設行為） |
| `interrupt_mitigation=0` | 不需要試（預設值本來就是 0） |

### 驅動參數預設值

從 `if_re` 模組的 `.data` / `.bss` 區段讀出：

| 參數 | 預設值 | 說明 |
|---|---|---|
| `msi_disable` | **1** | 停用 MSI → **X99-F8D 要改成 0** |
| `msix_disable` | 1 | 停用 MSI-X |
| `re_poll_intr` | 1 | 每秒輪詢一次中斷（保底機制） |
| `phy_power_saving` | 1 | PHY 省電 |
| `eee_enable` | 0 | 節能乙太網路（EEE） |
| `interrupt_mitigation` | 0 | 中斷合併 |

---

## 6. 傳送 ISO 到 datastore

### 方法 A：讓 ESXi 直接下載（最快）

ESXi 內建的 `wget` 會先嘗試 IPv6，失敗後不會改試 IPv4；內建 Python 則沒有公開網站的 CA 憑證。所以改用 **Python + HTTP** 下載，下載完再用 SHA256 驗證檔案。

```bash
esxcli network firewall ruleset set -e true -r httpClient

mkdir -p /vmfs/volumes/datastore1/ISO/Linux/ubuntu && cd /vmfs/volumes/datastore1/ISO/Linux/ubuntu
python -c "import urllib.request as u,sys;f='ubuntu-24.04.5-live-server-amd64.iso';u.urlretrieve('http://releases.ubuntu.com/24.04.5/'+f,f,lambda b,s,t:sys.stdout.write('\r%5.1f%%  %d MB'%(b*s*100/t,b*s>>20)))"

mkdir -p /vmfs/volumes/datastore1/ISO/Linux/RockyLinux && cd /vmfs/volumes/datastore1/ISO/Linux/RockyLinux
python -c "import urllib.request as u,sys;f='Rocky-9.8-x86_64-minimal.iso';u.urlretrieve('http://dl.rockylinux.org/pub/rocky/9/isos/x86_64/'+f,f,lambda b,s,t:sys.stdout.write('\r%5.1f%%  %d MB'%(b*s*100/t,b*s>>20)))"

sha256sum /vmfs/volumes/datastore1/ISO/Linux/*/*.iso
esxcli network firewall ruleset set -e false -r httpClient
```

| 檔案 | 官方 SHA256 |
|---|---|
| `ubuntu-24.04.5-live-server-amd64.iso` | `97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8` |
| `Rocky-9.8-x86_64-minimal.iso` | `d338032cd1cdd41c67139f2f71b4c832c8e4a21943106519db9c7137df7a63d4` |

### 方法 B：SFTP / SCP

1. 在 Host Client 開啟 SSH：**Manage → Services → TSM-SSH → Start**。
2. 從電腦上傳：

   ```bash
   scp your.iso root@<ESXI_IP>:/vmfs/volumes/datastore1/ISO/
   ```

- ESXi 8 的 SSH 只接受 keyboard-interactive 登入。FileZilla 請把登入類型設為「**互動式 (Interactive)**」。
- root 連續輸錯 5 次密碼會被鎖 **15 分鐘**。FileZilla 每次連線會重試 3 次，所以很容易被鎖。

### 方法 C：Host Client 網頁上傳

上傳卡在 0% 時，先在同一個瀏覽器開 `https://<ESXI_IP>/`，接受憑證警告，然後**完全關閉瀏覽器再重開**。

---

## 7. 疑難排解

### 快速檢查網卡

```bash
esxcli network nic list
esxcli network nic stats get -n vmnic0 | grep -E "Packets received|Total receive errors"
grep -i if_re /var/log/vmkernel.log | tail -20
ping -c 10 -i 0.2 <GATEWAY_IP> | tail -2
```

| 結果 | 原因 | 處理 |
|---|---|---|
| ping 閘道約 1000 ms，或 0～1000 ms 均勻分布 | INTx 中斷無效 | 見[第 5 節](#5-網路極慢延遲約-1-秒改用-msi-中斷) |
| `Link speed` 是 100 Mbps 或 Half duplex | 網路線或交換器埠的問題 | 換網路線或交換器埠 |
| ESXi 的 ping 正常，但從電腦上傳仍然很慢 | 電腦端的網路 | 見下方 |

### 先排除電腦端的問題

先測一下電腦到**自己的路由器**有沒有掉包：

```bash
ping -c 50 -i 0.2 <ROUTER_IP> | tail -2
```

實際遇過的案例：Mac 走 Wi-Fi，連到自己的路由器就掉了 30% 的封包，而且和 ESXi 不在同一個網段，中間還要經過路由器轉送。解法是讓 ESXi 直接下載（方法 A），或讓電腦接網路線、接到和 ESXi 同一台交換器。

### 硬碟寫入速度

```bash
time dd if=/dev/zero of=/vmfs/volumes/datastore1/ddtest.bin bs=1M count=1024; rm -f /vmfs/volumes/datastore1/ddtest.bin
```

1GB 在 10 秒內寫完（超過 100 MB/s），就表示硬碟不是瓶頸。

### 還原所有網卡相關設定

在主機螢幕前按 ALT+F1 登入：

```bash
esxcli system module parameters set -m if_re -p ""
esxcli system settings kernel set -s iovDisableIR -v FALSE
reboot
```

---

## 技術細節

<details>
<summary>為什麼不用 PowerCLI Image Builder？</summary>

一般製作自製 ISO 的做法，是用 PowerCLI 的 `Add-EsxSoftwareDepot` 載入 **offline depot (.zip)**，加入驅動後再 `Export-EsxImageProfile`。但免費版 ESXi 8.0U3e 只提供 ISO，不提供 depot，而 Image Builder 不能讀 ISO。

本 repo 改用 William Lam 針對「只有免費 ISO」的做法：只讓安裝程式透過 `boot.cfg` 載入驅動，裝好後再用 `esxcli software component apply` 正式安裝。

</details>

<details>
<summary>ISO 修改的驗證結果</summary>

| 檢查 | 結果 |
|---|---|
| 檔案數 | 138 → 139（只多了 `IFRE.V00`） |
| 未修改的檔案 | 134 個與原始 ISO 逐位元組相同 |
| `BOOT.CFG` ×2 | 只有 `kernelopt` 與 `modules` 兩處不同，兩份內容一致 |
| `ISOLINUX.BIN` | 只差 offset 8 和 12（重新封裝時自動改寫的檔案位置資訊） |
| `BOOT.CAT` | 重新產生（檔案位置改變），屬正常 |
| `EFIBOOT.IMG` | 完全相同。裡面只有 `BOOTX64.EFI`，UEFI 開機時會讀取 ISO 上的 `/EFI/BOOT/BOOT.CFG` |
| El Torito | BIOS 和 UEFI 開機項目都保留。UEFI 的載入大小改成 2048 個 512-byte 磁區，剛好等於 `EFIBOOT.IMG` 的 1 MiB |
| 前 32KB 系統區 | 與原始 ISO 相同 |
| `IFRE.V00` | 符合 VIB 宣告的 3 組校驗碼（sha-256 ×2、sha-1） |
| 驅動相依 | `vmkapi_2_10_0_0`，8.0U3e 有提供 |
| 驅動支援的 PCI ID | `10ec:8125 / 8126 / 8127 / 8136 / 8161 / 8162 / 8167 / 8168 / 8169` |

</details>

<details>
<summary>為什麼會「每秒才收一次封包」（反組譯 re_tick）</summary>

```asm
re_tick:
    mov    eax, [re_poll_intr]     ; 預設值 = 1
    test   eax, eax
    je     skip
    call   [rdi+0x14148]           ; 主動呼叫中斷處理函式（代替中斷收封包）
skip:
    ...
    call   re_start_timer          ; 1 秒後再執行一次
```

硬體中斷沒有送達時，所有收到的封包只能靠這個每秒一次的計時器取出，所以延遲固定在約 1 秒。改用 MSI 之後，網卡直接把中斷寫到 CPU，不再經過主機板 BIOS 的 INTx/IRQ 路由，問題就消失了。

</details>

---

## 參考資料

- William Lam — [Realtek Network Driver for ESXi](https://williamlam.com/2025/11/realtek-network-driver-for-esxi.html)
- William Lam — [Installing Realtek Network Driver Fling using Free ESXi 8.0 Update 3e ISO](https://williamlam.com/2026/02/installing-realtek-network-driver-fling-using-free-esxi-8-0-update-3e-iso.html)
- Andy's World — [How to create a custom ESXi 8.0 ISO with the Realtek driver Fling](https://andysworld.org.uk/2026/01/28/how-to-create-a-custom-esxi-8-0-iso-with-the-realtek-driver-fling/)
- Broadcom KB 399823 — [VMware ESXi 8.0 Update 3e now available as a Free Hypervisor](https://knowledge.broadcom.com/external/article/399823/vmware-esxi-80-update-3e-now-available-a.html)
- OSSLab — [免費合法 ESXi 8（autoPartitionOSDataSize）](https://osslab.tv/2025-free-serial-number-free-legal-esxi-8/)

## 免責聲明

- Realtek Fling 驅動是 VMware Fling，**不在官方支援範圍內**，僅建議用於 homelab。
- 本 repo 只包含腳本與文件，不散布任何 VMware / Broadcom 的二進位檔案。
- 使用風險自負。如果需要穩定的生產環境，建議加裝 ESXi 原生支援的 Intel 網卡（例如 I210、I350、X540）。

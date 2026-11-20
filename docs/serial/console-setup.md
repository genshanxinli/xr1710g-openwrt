# XR1710G 串口调试环境（WSL2 + usbipd-win）

目标：主机（WSL2）上恢复 `/dev/ttyUSB0`，可用 115200 8N1 打开 XR1710G 的 U-Boot / 内核控制台。

本文分三部分：**现状诊断**（2026-11-20 实测）、**Windows 侧操作单**（需要人工执行、需要管理员）、**WSL 侧操作单与验证**。最后是排查表和实测证据。

---

## 1. 现状诊断（2026-11-20 实测）

| 检查项 | 结果 | 结论 |
| --- | --- | --- |
| `uname -r` | `6.18.58.1-microsoft-standard-WSL2` | 真 WSL2，不是原生内核 |
| `/dev/ttyUSB*` | 不存在 | 串口没进来 |
| `/sys/bus/usb/devices/` | 初始不存在；`sudo modprobe vhci-hcd` 后出现 `usb1`/`usb2` 两个根 hub | 内核有 USB 栈，只是没有物理/虚拟主控加载，也没有设备 |
| `modinfo ch341` | `/lib/modules/6.18.58.1-microsoft-standard-WSL2/kernel/drivers/usb/serial/ch341.ko` | 驱动在，可随时 `modprobe ch341` |
| Windows `usbipd` 服务 | `Running`（`C:\Program Files\usbipd-win\usbipd.exe server`，usbipd-win **5.3.0**） | Windows 侧已装且在跑 |
| `usbipd list` | `1-3  1a86:7523  USB-SERIAL CH340 (COM5)  Shared` | **设备就在 Windows 上，状态是 Shared（已 bind，未 attach）** |
| `usbipd attach --wsl --busid 1-3` | `error: Networking mode 'consomme' is not supported.` | 卡在这里：WSL 的 networkingMode 是 `Consomme`，usbipd-win 5.3.0 不支持 |
| `C:\Users\l1nxi\.wslconfig` | `[wsl2]` / `networkingMode=Consomme` | 确认了上面的错误来源 |
| WSL → `172.19.0.2:3240` TCP | 可建立连接；但 `usbip list -r 172.19.0.2` 与手工 `usbip attach` 都挂住无响应 | consomme 下 usbipd 的导出通道不可用，手工 attach 也走不通 |
| WSL 内 `usbip` 命令 | `/usr/bin/usbip` 是 linux-tools 包装脚本，按 `uname -r` 找 `/usr/lib/linux-tools/<ver>/usbip`；WSL 内核没有对应目录 → 只打印警告 | 需要按第 3 节补一个可用二进制 |
| Windows 当前 PowerShell 权限 | `IsInRole(Administrator) = False` | 改 `.wslconfig` 和 `wsl --shutdown` 必须由人在管理员窗口做 |

一句话：**USB 设备和驱动都没问题，坏在 WSL 的网络模式（Consomme）与 usbipd-win 5.3.0 不兼容，且修复动作需要 Windows 管理员权限。** 这不是 ch341 模块问题，也不是线松了——`dmesg` 里旧的那次 attach/disconnect 属于上一个 WSL 实例，本实例从未 attach 过。

---

## 2. Windows 侧操作单（人工，管理员 PowerShell）

以管理员身份打开 PowerShell（Win+X → “终端(管理员)”）。

```powershell
# 1. 确认服务和设备（usbipd 不在默认 PATH，用全路径）
& 'C:\Program Files\usbipd-win\usbipd.exe' list
# 期望看到：1-3  1a86:7523  USB-SERIAL CH340 (COM5)  Shared

# 2. 如果 STATE 是 Not shared，先 bind（需要管理员）
& 'C:\Program Files\usbipd-win\usbipd.exe' bind --busid 1-3

# 3. 直接 attach 会报 consomme 不支持，这是已知阻塞点
& 'C:\Program Files\usbipd-win\usbipd.exe' attach --wsl --busid 1-3
```

### 2a. 首选修法：把 WSL 网络模式改回 NAT（需要管理员 + 重启 WSL）

```powershell
notepad C:\Users\l1nxi\.wslconfig
# 把 [wsl2] 段改成：
#   [wsl2]
#   networkingMode=nat
# 保存后彻底重启 WSL：
wsl --shutdown
```

然后在**新的** WSL 会话里重新 `usbipd attach`（或直接跑第 3 节的验证）。注意 `wsl --shutdown` 会结束当前所有 WSL 会话与终端，属于可回滚操作：改回 `networkingMode=Consomme` 再 `wsl --shutdown` 即恢复原状。代价是 NAT 模式下 WSL 的入站端口转发行为与 consomme 略有差异（如需固定端口，用 `netsh interface portproxy` 补规则）。

### 2b. 备选修法：升级 usbipd-win

consomme 支持由 usbipd-win 上游跟进；升级到支持该模式的版本后再执行：

```powershell
winget upgrade --id dorssel.usbipd-win
& 'C:\Program Files\usbipd-win\usbipd.exe' attach --wsl --busid 1-3
```

在 5.3.0 上这一步仍会报 `Networking mode 'consomme' is not supported`，不要把报错当成设备问题。

### 2c. attach 成功后的期望

```powershell
& 'C:\Program Files\usbipd-win\usbipd.exe' list
# 1-3  1a86:7523  USB-SERIAL CH340 (COM5)  Attached
```

Windows 侧到此为止；`--auto-attach` 可加在 attach 命令里，让设备重插后自动回来。

---

## 3. WSL 侧操作单（普通用户即可，除 modprobe/权限外）

```bash
# 0. 每次 WSL 新会话先加载虚拟主控与串口驱动（不加载时 /sys/bus/usb 都不存在）
sudo modprobe vhci-hcd
sudo modprobe ch341

# 1. 修 /usr/bin/usbip 包装脚本：给当前 WSL 内核补一份可用的 usbip 二进制
#    （Ubuntu 的 linux-tools 只带原生内核版本；WSL 内核没有对应目录）
sudo mkdir -p "/usr/lib/linux-tools/$(uname -r)"
sudo cp /usr/lib/linux-tools-*/usbip "/usr/lib/linux-tools/$(uname -r)/usbip"
usbip version          # 期望：usbip (usbip-utils 2.0)，不再打印 not found 警告
# 若系统里连 linux-tools 都没有：sudo apt install -y linux-tools-common usbip hwdata

# 2. 设备枚举工具（可选，便于取证）
sudo apt install -y usbutils
lsusb -d 1a86:          # 期望：1a86:7523 QinHeng Electronics CH340 serial converter

# 3. 串口节点与权限
ls -l /dev/ttyUSB*
sudo usermod -aG dialout "$USER"      # 之后需要重新登录（或 newgrp dialout）才生效
sudo chmod 660 /dev/ttyUSB0           # 单次临时放行，重插后可能复位

# 4. 验证能打开（20 秒原始字节，Ctrl-C 可提前结束）
timeout 20 cat -v /dev/ttyUSB0 | head -200
```

### 3a. 手工 attach（`usbipd attach --wsl` 不可用时的备选）

NAT 模式下 usbipd server 监听 Windows 的 3240，WSL 里直接 attach：

```bash
hostip=$(ip route show default | awk '{print $3; exit}')
sudo usbip list -r "$hostip"          # 期望列出 1-3: 1a86:7523
sudo usbip attach -r "$hostip" -b 1-3
ls -l /dev/ttyUSB*
```

consomme 模式下这条通道实测不可用（连接能建立但无协议响应），所以它只在 2a 之后有意义。

### 3b. 用仓库脚本开控制台 / 抓启动日志

```bash
# 交互式控制台，自动挑 picocom > minicom > screen > cu
scripts/serial/xr1710g-console.sh --log logs/console-$(date +%s).log

# 只看解析出的命令（无串口时也返回 0）
scripts/serial/xr1710g-console.sh --dry-run

# 抓一次完整启动日志：--reboot 先 ssh 让板子重启，再从串口抓
scripts/serial/boot-log-capture.sh --reboot --seconds 90

# 串口不可用时自动降级到 ssh dmesg，并在文件头标注
scripts/serial/boot-log-capture.sh --via ssh
```

`logs/` 已被 `.gitignore` 忽略（第 13 行 `/logs`），抓到的日志只留在本机。

---

## 4. 排查表

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `usbipd list` 里没有 1-3 | USB 线/口、设备没上电 | 换线换口，Windows 设备管理器看 COM5 是否在 |
| `usbipd attach` 报 consomme | WSL 网络模式与 usbipd-win 不兼容 | 走 2a（改 NAT）或 2b（升级） |
| attach 报 `Access denied` | 未 bind 或非管理员 | 管理员窗口 `usbipd bind --busid 1-3` |
| WSL 无 `/sys/bus/usb` | `vhci-hcd` 未加载 | `sudo modprobe vhci-hcd` |
| 有 `/sys/bus/usb` 但无 `/dev/ttyUSB0` | ch341 未加载 / 设备未 attach 到本 distro | `sudo modprobe ch341`；`usbip port` 看导入状态 |
| `/dev/ttyUSB0` 打不开 | 不在 dialout 组 | `sudo usermod -aG dialout $USER` 后重新登录 |
| 能打开但无输出 | 板子没输出 / TX 未接 / 波特率不是 115200 | 按复位键；确认 GND/TX/RX 交叉；115200 8N1 |
| `usbip` 打印 not found | linux-tools 与 WSL 内核版本不匹配 | 第 3 节第 1 步补二进制 |

---

## 5. 实测证据（2026-11-20，本机）

```
$ uname -r
6.18.58.1-microsoft-standard-WSL2

$ & 'C:\Program Files\usbipd-win\usbipd.exe' list
Connected:
BUSID  VID:PID    DEVICE                                STATE
1-2    2023:f024  USB 输入设备                          Not shared
1-3    1a86:7523  USB-SERIAL CH340 (COM5)               Shared
1-5    04f2:b7dd  HD Webcam, IR Camera                  Not shared
1-14   8087:0033  英特尔(R) 无线 Bluetooth(R)            Not shared

$ usbipd attach --wsl --busid 1-3
usbipd: info: Using WSL distribution 'Ubuntu' to attach; the device will be available in all WSL 2 distributions.
usbipd: info: Detected networking mode 'consomme'.
usbipd: error: Networking mode 'consomme' is not supported.

$ cat /mnt/c/Users/l1nxi/.wslconfig
[wsl2]
networkingMode=Consomme

$ sudo modprobe vhci-hcd && ls /sys/bus/usb/devices/
1-0:1.0  2-0:1.0  usb1  usb2        # 只有两个虚拟根 hub，没有 1-3

降级抓取（串口不可用，走 ssh）：
$ scripts/serial/boot-log-capture.sh --via ssh
boot-log-capture.sh: serial unavailable, captured via ssh
captured 366 lines via ssh dmesg
锚点：Machine model: Gemtek XR1710G (OpenWrt U-Boot layout) /
      FIT: Detected U-Boot XR1710G-2026-10-16-g94476aa18f0b-dirty /
      airoha-npu: NPU fw version 0.8 / mt7996e WM Firmware ... /
      airoha_eth ... RTL8261BE 10Gbps PHY
```

所以串口恢复的**唯一剩余阻塞点**是 Windows 管理员侧的网络模式（或 usbipd 升级）；WSL 侧驱动、工具、脚本都已就绪。

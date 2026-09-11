# 02 — 方案二：netbird 内核态 WireGuard + NEON 内核加解密

> 上游：`plan/00-总纲-架构与供给链.md`
> 依据：`research/NetBird方案深度调研-2026-09-11.md`、`research/PROXY-CRYPTO-EIP93-2026-09-10.md`、`research/EIP93-*-RESEARCH-2026-09-10.md`

---

## 1. 目标与判据

| 判据 | 内容 |
|---|---|
| P2-1 | **`netbird status -d` 报 `Interface type: Kernel`**（用户明确要求；内核 WG 而非 userspace wireguard-go） |
| P2-2 | `ip rule show` 含 `not from all fwmark 0x1bd00 lookup netbird` |
| P2-3 | ACL 生效（`NETBIRD-ACL-INPUT` 非空）——依赖 `kmod-ipset`/`kmod-ipt-ipset`（官方包只依赖 `+kmod-wireguard`，缺 ipset 时 ACK 规则**静默回滚为空** → 去往 peer 自身 IP 的流量被 DROP，openwrt/packages #7134） |
| P2-4 | `state.json` 落在 `/var/lib/netbird/`（tmpfs）而非 overlay ⇒ 运行期零 NAND 写 |
| P2-5 | 非隧道流量的 offload 不受影响；**隧道流量不承诺 offload**（见 §3） |

---

## 2. 术语澄清：`neon` = ARM NEON SIMD 内核加密

**不是独立项目、不是包、不是代理核心。** 全部研究文档中 `neon` 的唯一含义是 ARM **Advanced SIMD**，此处特指内核的 NEON 版 ChaCha20/Poly1305/Curve25519 实现。

- `target/linux/airoha/an7581/config-6.18`：**无 `CONFIG_ARM64_CRYPTO`、无 `CONFIG_CRYPTO_CHACHA20_NEON`**（只有 `CRYPTO_CRC32C/ECB/DEFLATE` 等）；
- `target/linux/generic/config-6.18`：`# CONFIG_CRYPTO_CHACHA20_NEON/POLY1305_NEON/CURVE25519_NEON is not set`，但 `CONFIG_KERNEL_MODE_NEON=y` **是开的**；
- 对照 `target/linux/armsr/armv8/config-6.18`：`CONFIG_ARM64_CRYPTO=y` + `CONFIG_CRYPTO_CHACHA20_NEON=y`。

⇒ **限制在 target config 选择，不是 CPU 能力。**（本机 `/proc/cpuinfo` = `fp asimd evtstrm crc32 cpuid`，无 AES/SHA 扩展，F11。）

> 工作区里另有一个**无关**的 `libneon` 包（HTTP/WebDAV 客户端库），与本方案无关。

---

## 3. 吞吐现实（必须先说清楚，避免预期错位）

| 事实 | 含义 |
|---|---|
| **EIP93 没有 chacha20/poly1305**（只注册 `cbc(aes)/ctr(aes)/rfc3686(ctr(aes))/ecb(...)` + 16 个 authenc；`gcm=0 ccm=0 xts=0 chacha20=0 poly1305=0`） | **WireGuard 永远拿不到 EIP93**（算法固定为 ChaCha20-Poly1305） |
| AN7581 的 SOE 只认 **ESP/NAT-T**（且驱动仍是未合入的 RFC） | 只对 IPsec 有意义，且本轮不做 |
| NEON 版 ChaCha20/Poly1305 **未编进 airoha target** | 内核 WG 跑**标量 C** |
| PPE/NPU 卸载只作用于**未加密的桥内/NAT 转发快路径** | **隧道流量进出 `wt0` 必然过 CPU**；本仓已毕业的 NPU/flow-offload 能力与 netbird 吞吐**无关** |
| NetBird 官方 sizing：userspace 4 核 ≈6.8 Gbps，kernel 态 16 vCPU ≈20 Gbps（原文「roughly 6x below kernel WireGuard」） | 必须坚持**内核 WG** |
| 参考值 578 Mbps（ChaCha20-Poly1305 单核~72 MB/s）是 **Go 用户态**参照，**不是内核 WG 上限** | 真实上限必须**实机 iperf3 实测**；不引用任何未经复现的数字 |

---

## 4. 实现分解

### 4.1 自持 netbird 包（`packages-xr1710g/package/netbird/`）
- 提版 `0.78.1`（官方 feed 是 `0.73.2`，正是 #6953 内存泄漏报告版本：管理面不可达 ⇒ RSS 膨胀 / 单核占满）；
- `PKG_HASH` 按**锁源铁律**实算复核，登记 `docs/FIXES.md`；
- 依赖补 `+kmod-ipt-ipset`（P2-3）；
- 构建：`CGO_ENABLED=0 GOOS=linux GOARCH=arm64`，产出静态链接二进制；
- 上游 `#30370`/`#30406`（update to 0.78.1）合入后删除自持包。

### 4.2 配置（全部**默认不启用**）
- `network.netbird`：`proto none` / `device wt0`；
- `firewall` zone `netbird`（ACCEPT×3、`masq=1`）+ `lan ↔ netbird` 双向 forwarding；
- `dnsmasq`：`server='/<你的DNS域>/127.0.0.1#5053'`；netbird 侧固定 `--dns-resolver-address 127.0.0.1:5053`（内核态下 `100.x.255.254` 本地解析器不可达，这是官方给出的功能完备解）；
- **不在 LuCI 里配任何 WireGuard 接口**（`wt0` 归 netbird 管）。

### 4.3 NEON（`#EXP` 实验档）
- 新增 `patches/.../airoha-999-crypto-neon.patch`，对 `target/linux/airoha/an7581/config-6.18` 增：
  `CONFIG_ARM64_CRYPTO=y`、`CONFIG_CRYPTO_CHACHA20_NEON=y`、`CONFIG_CRYPTO_POLY1305_NEON=y`、`CONFIG_CRYPTO_CURVE25519_NEON=y`；
- **先入 `#EXP`**（研究明令「禁止凭理论直接进 default」）；
- 注意：改变内核 config ⇒ **config hash 变** ⇒ kmods feed 必须同一次构建产出（`00-总纲` §4.4）。

### 4.4 冲突面登记
- 本仓**当前无 pbr/mwan3** ⇒ 零冲突；
- 将来上 pbr：`uplink_ip_rules_priority='99'`；pbr 的 `uplink_mark/fw_mask` 由 `00010000/00ff0000` 改为 `00100000/0ff00000`；必要时 `NB_USE_LEGACY_ROUTING=true`；
- netbird 走 **nftables 后端**的前提需实机确认（探测失败会退回 iptables，#4484/#3363）；
- exit-node 场景与本机 PPE/NPU flow offload + fw4/nftables 的共存**属未实测项**，只影响 exit-node 用例，本轮不做 exit node。

### 4.5 明确排除
| 排除项 | 理由 |
|---|---|
| `--enable-rosenpass` | 默认 false，保持默认；管理端强制时设 `NB_PROXY_ROSENPASS=false` 并上报 |
| `NB_USE_NETSTACK_MODE`（gVisor 用户态栈） | 官方明示 DNS 不支持、只能按 IP 访问 peer、不能当网关 |
| 容器化 / 路由器自托管控制面 | 与「350 MiB overlay + 2.26 MB/s 写入」冲突 |
| exit node | 与 PPE/NPU offload 共存属未实测项 |

---

## 5. 验收要点（细则见 `04-验收与测试矩阵.md`）

- `netbird status -d`：`Management/Signal: Connected`、**`Interface type: Kernel`**、`Quantum resistance: false`；
- `iptables -L NETBIRD-ACL-INPUT -n -v` 非空（P2-3）；
- `ip rule show` 含 `not from all fwmark 0x1bd00 lookup netbird`；
- 远端 ping/ssh 通；**72h RSS 线性不增长**；
- `sysupgrade` 后仍 Connected（二进制随固件版本回退，需登记）；
- `state.json` 在 `/var/lib/netbird/`（tmpfs）；
- **NEON A/B**：`grep -A3 chacha20 /proc/crypto` 出现 `chacha20-neon`（若不出现 ⇒ 研究判断需更正）+ 过 WG 的 iperf3 对照；
- 非隧道流量：`ppe/bind` 计数与吞吐不受影响。

# ADR 0006 — 方案二供给链：netbird 自持提版 + NEON 零补丁结论 + kmod 必须预装

**Status**: accepted（2026-09-11 评审确定；`plan/02` 的「NEON 补丁」机制在实施期被内核源码核对推翻，见 §3）
**Context**:
方案二的硬要求是 **`netbird status -d` 报 `Interface type: Kernel`**（plan/06 第 1 轮 Q2 用户自定义），
即必须是内核态 WireGuard 而非 userspace wireguard-go。这牵出三件互相独立的事：

1. 官方 feed 只有 `netbird 0.73.2`，早于 v0.76.0 的本地提权修复（GHSA-qcpp-8vwj-hhwr）；
2. `plan/02` §2/§4.3 主张「NEON 未编入 airoha target，需加 `CONFIG_ARM64_CRYPTO` + 三项 NEON 补丁」；
3. 运行期能不能装 kmod。

**Decision**:

### 1. netbird 用**补丁层提版**，不 vendor 整包

`patches/packages/netbird-0001-bump-to-0.78.1-and-ipset-dep.patch` → 落到 `package/feeds/packages/net/netbird/patches/`，
只改三行：`PKG_VERSION` 0.73.2→0.78.1、`PKG_HASH` 同步、`DEPENDS` 增补 `+kmod-ipt-ipset`。

- `PKG_HASH := 2adde8bbd77ea595b5f50174be10574466f1c07fc9fbf827024245aec2f4dabc`（**实算**，非抄 PR）。
  方法自证：对 0.73.2 tarball 实算得 `ba8d1615a6676e6d17f5d4a3c8027cd2e7437c862da3f963d3b337c09efff423`，
  与上游 Makefile 里已声明的值逐字符相同 ⇒ 同一方法算出的 0.78.1 值可信。
- 不加 `PKG_MIRROR_HASH`（上游没有；不加则跳过 OpenWrt 镜像、直取 codeload，加了反而多一个待同步的第二真相源）。
- 为什么不 vendor 整包：本仓库的既定模型是「补丁层 + 上游 feed」（ADR-0001）。vendor 会复制 `files/netbird.init`
  等全部内容，造成与上游的双份真相与长期漂移；改动只有三行，补丁层的成本低一个数量级。
  上游 PR #30370 / #30406 合入即删本补丁。

### 2. `+kmod-ipt-ipset` 是**刻意的本地偏离**，不是上游依赖

上游 `DEPENDS` 从来只有 `$(GO_ARCH_DEPENDS) +kmod-wireguard`（feed 历史上只改过两次，均与此无关）。
本仓库加 `+kmod-ipt-ipset` 的理由与边界：

- netbird 的 ipset 依赖**只作用于 iptables 后端**；nftables 后端用原生 nft set（`github.com/google/nftables`），不需要 ipset；
- 0.73.2 缺 ipset 时会把 ACL 规则**静默回滚为空**（netbirdio/netbird#7134）。0.78.1 已含 v0.77.0 的
  `probeIPSetSupport` 回退 ⇒ 该失败模式本身已被上游修掉；
- 保留 `+kmod-ipt-ipset` 是 belt-and-braces：一旦后端探测失败退回 iptables（见 #4484/#3363），ACL 仍能建立。
  代价几十 KB，值得；
- ⚠️ **不存在 `kmod-ipset` 这个包名**——提供 `IP_SET_HASH_NET` 的只有 `kmod-ipt-ipset`（`netfilter.mk:403`）。
  写错包名会在构建期依赖解析失败。

不加 `+ca-bundle`：默认镜像的 `DEFAULT_PACKAGES` 已含 `ca-bundle`（`include/target.mk`），
netbird 的 `x509.SystemCertPool()` 有证书源。只有 imagebuilder/裁剪镜像才需要显式加。

### 3. **NEON 不需要任何补丁**（推翻 `plan/02` §4.3）

`plan/02` 主张新增 `airoha-999-crypto-neon.patch`，加 `CONFIG_ARM64_CRYPTO` + `CONFIG_CRYPTO_CHACHA20_NEON`
+ `CONFIG_CRYPTO_POLY1305_NEON` + `CONFIG_CRYPTO_CURVE25519_NEON`。**对 kernel 6.18.44 核对后：这三个符号不存在，
且 `CONFIG_ARM64_CRYPTO` 也已不是 arm64 加密算法的开关。**

内核 6.18 的实际机制（`lib/crypto/Kconfig` / `lib/crypto/Makefile`，逐行核对）：

```kconfig
config CRYPTO_LIB_CHACHA
	tristate
	select CRYPTO_LIB_UTILS
config CRYPTO_LIB_CHACHA_ARCH
	bool
	depends on CRYPTO_LIB_CHACHA && !UML && !KMSAN
	default y if ARM64 && KERNEL_MODE_NEON      # ← 关键
# CRYPTO_LIB_POLY1305_ARCH 同款；CRYPTO_LIB_CURVE25519_ARCH 为 `default y if ARM && ...`
```

```make
libchacha-$(CONFIG_ARM64) += arm64/chacha-neon-core.o   # lib/crypto/Makefile
```

而 `drivers/net/Kconfig` 里 WireGuard 自身 select 了这三者：

```kconfig
config WIREGUARD
	select CRYPTO_LIB_CURVE25519
	select CRYPTO_LIB_CHACHA20POLY1305
```

**结论**：本机 `CONFIG_KERNEL_MODE_NEON=y` 已开（generic/config-6.18:3203），
一旦启用 `kmod-wireguard`（其 OpenWrt 包依赖 `kmod-crypto-lib-chacha20poly1305` + `kmod-crypto-lib-curve25519`），
`_ARCH` 变体**自动 `default y`** ⇒ NEON 汇编直接编入内核，**零补丁、零 config 改动**。

⇒ 本分支**不新增 NEON 补丁**。验收改为离线断言（见 `scripts/check-kernel-offload-invariants.sh` 的 NEON 段）
+ 刷机后一次只读探测（`plan/02` §5 的「若 `chacha20-neon` 不出现 ⇒ 研究判断需更正」在此已提前更正）。

> 更正 `plan/02` §5 的一条判据：WireGuard 用的是内核 **library** 接口（`chacha_crypt_arch`/`curve25519`），
> 这些实现**不注册** `/proc/crypto` 算法名。因此「`grep -A3 chacha20 /proc/crypto` 出现 `chacha20-neon`」
> 这个验收动作**在本内核上不成立**（库接口不走 crypto API 注册）。正确判据见 §5。

### 4. kmod 必须**随固件预装**——运行期 ROUTE 已被实机封死

2026-09-11 实机取证（比 F5 更完整）：

- 官方 kmods 目录 `…/targets/airoha/an7581/kmods/6.18.44-1-<hash>/` **存在且发布**（wireguard/ipset/tproxy 都在）；
- 但设备 `distfeeds.list` 只挂了 `…/targets/airoha/an7581/packages/packages.adb`，**没有 kmods 这一项**；
- 更关键：本机构建 hash 与官方发布 hash **不同**。而 aarch64 的 `vermagic` =
  `6.18.44 SMP mod_unload aarch64`，**不含 config hash** ⇒ apk **不会**发现不匹配，属静默 ABI 风险。
- 实机 `apk add kmod-wireguard` → `(no such package)`；`apk list kmod-tun`（已装）也查不到。

⇒ 方案二内核态 WG **只能走"随固件预装 + 自建 kmods feed"**（`plan/00` §4.3/§4.4）。
本分支把 `kmod-wireguard` / `kmod-ipt-ipset` / `kmod-tun` / `kmod-nft-tproxy` 写进 `config/seed-config.diff`。

**Why（为什么值得为一个"看不见的优化"写这么长）**：
NEON 这一条正好是「凭理论直接进 default」的典型——`plan/02` 自己写了「禁止凭理论直接进 default」，
但它给的符号集在本内核上编译期就会失败。把机制核对清楚的结果是**少写一个补丁**，而不是多写一个。

**Considered Options**:
- **vendor 整个 netbird 包**（`packages-xr1710g/package/netbird/`）：能完全控制 init/conffiles，但要复制上游全部内容并长期跟踪；
  本次改动只有三行，成本收益不成立。否决。
- **保持 0.73.2 + 只用 `NB_PROXY_ROSENPASS=false` 缓解泄漏**：0.73.2 的静默 ACL 回滚是**功能**缺陷（不只是泄漏），
  且错失 GHSA-qcpp-8vwj-hhwr 提权修复。否决。
- **按 `plan/02` 加 NEON 补丁**：符号不存在 ⇒ 编译期无效果（kconfig 静默忽略未知符号，正是 F15 的教训），
  会留下一个"看起来做了事"的假补丁。否决。
- **运行期 `apk add` kmod**：实机已证不可行（见 §4）。否决。

**Consequences**:
- ✅ 方案二的内核态 WG 依赖一条清晰的供给链：自建 kmods feed（`plan/00` §4.4）+ 预装清单；
- ⚠️ `#6953`（`cunicu.li/go-rosenpass v0.5.42` 孤儿定时器导致内存泄漏）**0.78.1 并未修**（该版本仍 pin 在 go.mod）。
  提版收益是安全修复而非泄漏修复；缓解 = 保持 Rosenpass 关闭 + `NB_PROXY_ROSENPASS=false`。**不得**把提版宣传成"修了泄漏"。
- ⚠️ netbird 的 `state.json` 在 `/var/lib/netbird/`（tmpfs，零 NAND 写），但 `/root/.config/netbird/` 在 **overlay 上且是持久 conffile**
  ⇒ plan/02 的 P2-4「零 NAND 写」**只对 state.json 成立，对 overall 不成立**，必须如此表述；
- ⚠️ 设备**不**自动启用 netbird 服务（无 rc.d 链接、无 uci-defaults）⇒ 天然满足「预装但默认不启用」；
- ⚠️ netbird 0.78.1 是 **CGO_ENABLED=1 动态链接**（上游配方；`golang-package.mk` 强制 `CGO_ENABLED=1` + `-linkmode external`，
  改 `CGO_ENABLED=0` 会硬链接失败，本机已复现）。不要试图做"全静态"变体。

**§5 验收判据（取代 `plan/02` §5 的 NEON 行）**:

| 项 | 判据 |
|---|---|
| 内核 WG | `netbird status -d` 报 `Interface type: Kernel` |
| kmod 就位 | `ls /lib/modules/$(uname -r)/wireguard.ko` 存在；`lsmod` 含 `wireguard` |
| NEON 生效（离线） | 构建产物 `.config` 含 `CONFIG_CRYPTO_LIB_CHACHA_ARCH=y` / `CONFIG_CRYPTO_LIB_POLY1305_ARCH=y`（`_ARCH` 由 `default y` 推出） |
| NEON 生效（实机） | `grep -c 'chacha.*neon\|curve25519.*neon' /proc/kallsyms` 或对 `wireguard.ko` 做反汇编确认存在 NEON 指令（**不是** `/proc/crypto`） |
| ACL | `nft list ruleset \| grep -i netbird` 非空（nftables 后端）；退回 iptables 时 `iptables -L NETBIRD-ACL-INPUT -n -v` 非空 |
| 路由 | `ip rule show` 含 `not from all fwmark 0x1bd00 lookup netbird` |
| 写盘 | `ls -l /var/lib/netbird/state.json` 落在 tmpfs（`df` 挂载点非 `/overlay`）；`/root/.config/netbird/` 为已知例外 |

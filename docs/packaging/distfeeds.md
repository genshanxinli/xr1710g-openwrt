# distfeeds 发布：把 kmod 一起交给用户（D13）

## 一句话

每次构建把 apk 的 package feed（含 `kernel` 与全部 `kmod-*`）打成一个
`distfeeds.tar.gz`，跟镜像挂在同一个 release 上；用户从里面取包，**不**开
`owut` / attendedsysupgrade —— 在线升级会把人送到没测过的镜像上。

## 发布内容

`scripts/build-distfeeds.sh` 从已构建的树里取出所有带索引的包目录，落成与
`/etc/apk/repositories.d/distfeeds.list` 里 URL 同构的布局：

```
distfeeds/
  targets/<board>/<subtarget>/packages/   core：base-files、kernel、全部 kmod
    packages.adb  index.json  *.apk
  packages/<arch>/{base,luci,packages,...}/
    packages.adb  index.json  *.apk
  distfeeds.list   相对路径清单
  MANIFEST.json    每个 feed 的条目数与 kmod 数
  public-key.pem   校验用的公钥（私钥绝不发布）
```

release 资产名不能带目录，所以这棵树必须打成 tar 包；解开就是可直接服务的
目录。用法见下。

## 为什么不改 `include/feeds.mk`

apk 迁移之后 kmod 的索引**已经**是无条件生成的，`CONFIG_BUILDBOT` 那个分支
管的是另一件事：

- `rules.mk:201` `PACKAGE_DIR=$(BIN_DIR)/packages`，而 `rules.mk:155`
  `BIN_DIR=$(OUTPUT_DIR)/targets/$(BOARD)/$(SUBTARGET)` —— kmod 和
  `kernel` 就编在 `bin/targets/airoha/an7581/packages/`。
- `package/Makefile:183-205` 的 `package/index` 对所有包目录无条件跑
  `apk mkndx` + `scripts/make-index-json.py`，不看 `CONFIG_BUILDBOT`。
- `include/feeds.mk:56-57` 只在 `CONFIG_BUILDBOT=y` 时追加
  `targets/%S/kmods/<kver>/packages.adb`，那是 BuildBot 把 kmod 从 packages
  目录搬走之后用的独立目录。本仓的构建从不生成它
  （`bin/targets/airoha/an7581/` 下没有 `kmods/`），打开这个开关只会给设备
  写一条指向不存在路径的 repository 行；按上游 `53ee2e8c03` 的说明，重复的
  kmod 条目还会让 opkg/apk 犯迷糊。

本树的实测（见下）：core feed 的 `index.json` 79 条，其中 `kmod-*` 66 条 +
`kernel` 1 条，和实机已装的 171 个包一一对应。所以本仓在 `feeds.mk` /
`.config` 上**不需要**改动，缺的只是「把 `bin/` 里的包交出去」。

## 索引格式（apk 3.x，不是 opkg）

| 文件 | 作用 |
| --- | --- |
| `packages.adb` | apk 仓库索引（ADB 容器，`CONFIG_SIGNED_PACKAGES=y` 时带签名） |
| `index.json` | 同一份索引的 JSON 形式，人读与比对用 |

apk 时代没有 `index.tar.gz`、`Packages`、`Packages.gz`，也不需要自写
`apk index` 脚本：`make package/index` 已经是这件事（`package/Makefile:190-205`）。
`scripts/build-distfeeds.sh` 只做收集、校验与打包，不重新发明索引。

设备信任的 key 就是构建树里的 `public-key.pem`（`rules.mk:354-355`），
实机 `/etc/apk/keys/public-key.pem` 与本树该文件 sha256 相同；私钥
`private-key.pem` 只留在构建机。

## 使用方法

```sh
# 解到设备或任一静态目录
tar -xzf distfeeds.tar.gz -C /srv/distfeeds

# 设备侧：只往 customfeeds.list 加行，distfeeds.list 是构建产物会被覆盖
cat >> /etc/apk/repositories.d/customfeeds.list <<'LIST'
https://example.invalid/xr1710g/targets/airoha/an7581/packages/packages.adb
https://example.invalid/xr1710g/packages/aarch64_cortex-a53/base/packages.adb
https://example.invalid/xr1710g/packages/aarch64_cortex-a53/luci/packages.adb
LIST
apk update
```

没有 HTTP 服务时，`file://` 也可以（`include/image.mk:376` 的镜像构建就是这个
形式），离线可用。

**ABI 必须同源。** `kernel` 包带的是 `7.3~<源码 sha>`，kmod 依赖它；只有
`distfeeds` 与设备上跑的镜像出自同一个 source sha 时才能装。所以 feed 跟着
release tag 走（tag 里带 source sha），不要跨版本混用。

## 验证

```sh
# 本机构建树：条目数与 kmod 数
TOPDIR=$PWD ./scripts/build-distfeeds.sh /tmp/distfeeds
#   packages/aarch64_cortex-a53/base/index.json            70 packages    0 kmod/kernel
#   packages/aarch64_cortex-a53/luci/index.json            18 packages    0 kmod/kernel
#   packages/aarch64_cortex-a53/packages/index.json         4 packages    0 kmod/kernel
#   targets/airoha/an7581/packages/index.json              79 packages   67 kmod/kernel
#   total: 171 packages, 67 kmod/kernel

# 索引里确实有 kmod，且签名在
staging_dir/host/bin/apk adbdump /tmp/distfeeds/targets/airoha/an7581/packages/packages.adb | grep -c '^  - name: kmod-'

# 设备侧（只读，不改 /etc/apk/repositories）：从发布索引取一个 kmod
apk fetch --cache-dir /tmp/a6cache --arch aarch64_cortex-a53 \
  --repositories-file /dev/null \
  --repository file:///tmp/distfeeds/targets/airoha/an7581/packages/packages.adb \
  -o /tmp/a6dl kmod-airoha-eth
```

2026-11-20 的实测：实机 `apk-tools 3.0.5` 从该布局成功取到
`kmod-airoha-eth-7.3-r1.apk` 与 `base-files-1719~ed51227e8a.apk`，签名校验
通过（未加 `--allow-untrusted`）；同一台机器 `apk update` 打官方
`https://downloads.openwrt.org/snapshots/...` 仍是 `ERROR: wget: exited with
error 4`（设备无外网），说明缺的确实是本地/项目内的 feed，不是工具链。

## xr1710g-builds 侧需要的改动

本仓只能保证「构建树里有可发布的 feed」。真正让产物离开 runner 的是
`genshanxinli/xr1710g-builds`：

1. `Collect images` 之后加一步调用 `scripts/build-distfeeds.sh` 并打 tar；
2. `Release` 的 `gh release create "$TAG" out/*` 就会带上它（`out/*` 已经收）。

现成补丁：`docs/packaging/xr1710g-builds-build.yml.patch`（`git apply` 即可）。
本 PR 只做本仓侧与文档，不触发对方 350 分钟的全量构建。

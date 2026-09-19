# Firmware-Builder-Self

个人 OpenWrt 固件自动构建仓库 —— GitHub Actions + **seed 配置模式**(仿
[Qualcommax_NSS_Builder](https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder) 的
`devices/*/config` → `make defconfig` 体系)。

## 构建目标

| 设备 | 角色 | 源码 / 分支 | Target | seed |
|---|---|---|---|---|
| x86 软路由 | 主路由(AC,passwall 出国) | [immortalwrt](https://github.com/immortalwrt/immortalwrt) `master` | x86/64 generic | `configs/x86.seed` |
| 京东云无线宝 RE-SP-01B | 无线 AP | 同上 | ramips/mt7621 | `configs/jdcloud.seed` |
| Redmi AX6 | 无线 AP(NSS 硬件加速) | [openwrt-nss-edma](https://github.com/JuliusBairaktaris/openwrt-nss-edma) `nss-edma-rework` | qualcommax/ipq807x | `configs/redmi-ax6-nss.seed` |

Redmi AX6 的 NSS 栈(工具链优化、加固选项、NSS kmod 全家、sqm-nss、luci-app-nss 等)
移植自 Builder 的 `devices/common/config` + `ipq807x-512m` 组(512M 内存档),并在
`patches/feeds/luci/` 保留了其 DSCP 状态列 patch。Builder 的 `ppe` 相关内容
(PPE-only 测试线)不适用于本仓库。

## 工作原理

```
configs/<name>.seed ──┐
configs/feeds.<line> ─┤→ scripts/prepare-build.sh
patches/feeds/**      ─┘         │
                                 ├─ 1. feeds 注入 feeds.conf(--prepend 置顶覆盖 / 默认追加,幂等)
                                 ├─ 2. feed 补丁(patches/feeds/<feed>/*.patch,三态:打上/已应用跳过/失败)
                                 ├─ 3. seed → .config → make defconfig(依赖自动补全)
                                 ├─ 4. 硬校验:seed 显式 =y 的符号必须存活,否则构建失败
                                 └─ 5. 禁用自定义 feed 的 CONFIG_FEED_*(不打进固件 distfeeds)
```

**seed 只写"意图"**(要什么包、什么分区、什么档位),依赖关系交给 `make defconfig`
推导 —— 上游更新后重跑 defconfig 自动跟进,配置永不过期。

**硬校验是安全网**:Kconfig 对改名/依赖缺失的符号是静默丢弃的;脚本会在 defconfig
后逐一核对 seed 里的显式 `=y` 符号,任何一个没出现在最终 `.config` 就带清单失败
—— 绝不出"悄悄少包"的固件。

## 触发与产物

- **push 到 main**(改动 `configs/**`、`scripts/**`、workflow 文件时)或 **手动**
  Actions → Run workflow(`workflow_dispatch`)
- 三台设备并行构建,首跑约 2–3.5h(工具链从零),缓存命中后 30min–1.5h
- `dl/` 与 toolchain 按**周**缓存(actions/cache)
- 产物:每次构建的 **artifact**(90 天)+ 自动 **Release**(tag:
  `immortalwrt-<device>-<日期>` / `nss-redmi-ax6-<日期>`),Release 附最终完整
  `.config`(`config-full.defconfig`)与所用 seed,可追溯

刷机文件是各 Release 里的 `*-squashfs-sysupgrade.bin`(NSS 线仅 sysupgrade-only,
无 factory/initramfs;首次需已刷过 OpenWrt)。

## 改配置

1. 直接编辑 `configs/*.seed`(每文件头部有注释说明来源与取舍)
2. push → 自动构建;或想验证符号可先本地跑:
   ```sh
   cd ~/immortalwrt            # 任一 OpenWrt 构建树
   cp <seed> .config && make defconfig
   ```
3. 想用 menuconfig 探索:在真实 checkout 里 `cp seed .config && make menuconfig`,
   改完 `scripts/diffconfig.sh` 对照,把**意图级**差异写回 seed(不要整份拷贝,那会
   退化回完整 config 模式)

各 seed 的详细取舍记录:
- `configs/x86.seed` —— 提炼自 `reference/immortalwrt-x86.config`(403 包快照);
  passwall 走 nftables 模式,分流用 v2ray-geoip/geosite
- `configs/jdcloud.seed` —— 提炼自 `reference/immortalwrt-jdcloud-selector.txt`
  (包列表,47 包全命中);EIP93 硬件加密,mt7621 注意是 ramips 的 subtarget
- `configs/redmi-ax6-nss.seed` —— NSS 栈对齐 Builder edma-nss variant;自选包
  (wpad-openssl / luci-app-dawn / luci-app-statistics / 运维工具)提炼自
  `reference/openwrt-ipq-redmi-ax6.config`(旧 qosmio main-nss 时代的配置)

## 目录结构

```
├── .github/workflows/
│   ├── immortalwrt.yml      # x86-64 + jdcloud matrix
│   └── nss-redmi-ax6.yml    # 单设备
├── configs/                 # 生效配置(seed + feeds 注入表)
├── patches/feeds/           # feed 补丁(Builder 移植)
├── scripts/prepare-build.sh # 通用准备脚本
└── reference/               # 原始出处文件(仅存档,不参与构建)
```

## 背景:PPE / NSS / EDMA

IPQ807x 芯片上有两条平行的硬件加速路线 + 一条公共通道:

- **EDMA** — 以太网 DMA 驱动(搬运工,所有要 CPU 过手的包必经;已进 openwrt 主线)
- **PPE** — 交换机侧流表引擎(硬件转发/NAT,全开源;基础驱动已进主线
  [PR #22381](https://github.com/openwrt/openwrt/pull/22381),完全体
  [PR #24806](https://github.com/openwrt/openwrt/pull/24806) 审查中)
- **NSS** — 独立加速核 + 闭源固件 + ECM(性能上限最高、含 WiFi 卸载;因固件
  blob 永不进主线,只能活在 fork —— 即本仓库 NSS 线用的 nss-edma)

Redmi AX6 当 AP 用,主要负载是无线↔有线桥转发,正是 NSS(wifili)最吃的场景。

## 上游与参考

- https://github.com/immortalwrt/immortalwrt — ImmortalWrt master
- https://github.com/JuliusBairaktaris/openwrt-nss-edma — NSS fork(分支
  `nss-edma-rework`)
- https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder — seed 模式与 NSS
  栈的参考实现(其 `docs/CUSTOMIZE.md` 值得一读)
- https://github.com/JuliusBairaktaris/nss-packages — NSS 包 feed(`edma-nss`)
- passwall feeds 见 `configs/feeds.immortalwrt`

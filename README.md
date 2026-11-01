# Firmware-Builder-Self

Personal OpenWrt firmware build repository — GitHub Actions + **seed config
mode** (modeled after
[Qualcommax_NSS_Builder](https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder)'s
`devices/*/config` → `make defconfig` approach).

## Build Targets

| Device | Role | Source / Branch | Target | Seed |
|---|---|---|---|---|
| x86 box | Main router (gateway) | [immortalwrt](https://github.com/immortalwrt/immortalwrt) `master` | x86/64 generic | `configs/x86.seed` |
| JDCloud RE-SP-01B | Wireless AP | same | ramips/mt7621 | `configs/jdcloud.seed` |
| Redmi AX6 | Wireless AP (PPE wired offload + NSS Wi-Fi offload) | [openwrt-ppe-nss](https://github.com/JuliusBairaktaris/openwrt-ppe-nss) `ppe-nss` | qualcommax/ipq807x | `configs/redmi-ax6-ppe-nss.seed` |

The Redmi AX6 line follows the Builder's `ppe-nss` flavour: wired offload
runs in the PPE through in-kernel interfaces (fw4 flowtable, switchdev, tc
qdisc offload), and the NSS firmware takes only the Wi-Fi data path
(`kmod-nss-wifi-drv`, on by default). Toolchain/hardening options and the
PPE QoS stack (qca-ppe-qos + its LuCI page from the Builder's luci fork,
tc-tiny, sched kmods, DCB) come from the Builder's `devices/common/config`
+ upstream `seeds/qualcommax-nss-wifi.seed`; `patches/feeds/packages/`
repins sqm-scripts to the `hw_ppe` fork that drives the PPE port shaper.
The old vendor-NSS line (qca-nss-drv/ECM/sqm-nss) was archived upstream and
dropped here along with the switch.

## How It Works

```
configs/<name>.seed ──┐
configs/feeds.<line> ─┤→ scripts/prepare-build.sh
patches/feeds/**      ─┘         │
                                 ├─ 1. inject feeds into feeds.conf (--prepend = top priority / append, idempotent)
                                 ├─ 2. feed patches (patches/feeds/<feed>/*.patch; apply / skip-if-applied / fail)
                                 ├─ 3. seed → .config → make defconfig (dependencies resolved automatically)
                                 ├─ 4. hard check: every explicit =y symbol in the seed must survive,
                                 │     otherwise the build fails with a list
                                 └─ 5. disable CONFIG_FEED_* for custom feeds (kept out of image distfeeds)
```

**Seeds express intent only** (which packages, partition sizes, memory
profiles); dependency resolution is left to `make defconfig` — reruns after
upstream updates pick up changes automatically, so configs never go stale.

**The hard check is the safety net**: Kconfig silently drops symbols that
were renamed or whose dependencies are unmet. The script verifies every
explicit `=y` line from the seed against the final `.config` and fails with
a named list otherwise — a build that quietly omits a package never ships.

## Triggers and Artifacts

- **push to main** (changes under `configs/**`, `scripts/**`, or the workflow
  files) or manual **Run workflow** (`workflow_dispatch`)
- All three devices build in parallel; first run ~2–3.5h (toolchain from
  scratch), 30min–1.5h once caches are warm
- `dl/` and toolchain are cached **weekly** (actions/cache, restore + save
  with `if: always()` — a failed run still keeps its caches)
- Artifacts on every run + automatic **Releases** (tags:
  `immortalwrt-<device>-<date>` / `ppe-nss-redmi-ax6-<date>`), each release
  carries the final full `.config` (`config-full.defconfig`) and the seed it
  was built from, for traceability

The flashable file in each release is the `*-squashfs-sysupgrade.bin` (the
Redmi AX6 line is sysupgrade-only — no factory/initramfs; you must already
run OpenWrt to flash it).

## Changing the Configuration

1. Edit `configs/*.seed` directly (each file's header documents its origin
   and trade-offs)
2. Push → automatic build; to verify symbols locally first:
   ```sh
   cd ~/immortalwrt            # any OpenWrt build tree
   cp <seed> .config && make defconfig
   ```
3. To explore with menuconfig: `cp seed .config && make menuconfig` in a real
   checkout, then compare with `scripts/diffconfig.sh` and write **only the
   intent-level differences** back into the seed — never copy the whole
   file, or you regress to the full-config mode

Per-seed provenance:
- `configs/x86.seed` — distilled from `reference/immortalwrt-x86.config`
  (a 403-package snapshot); passwall runs in nftables mode, splitting via
  v2ray-geoip/geosite
- `configs/jdcloud.seed` — distilled from
  `reference/immortalwrt-jdcloud-selector.txt` (package list; all 47
  packages hit); EIP93 hardware crypto. Note mt7621 is a ramips subtarget
- `configs/redmi-ax6-ppe-nss.seed` — ppe-nss offload stack as shipped by
  the Builder (PPE wired + NSS Wi-Fi); user picks (wpad-openssl /
  luci-app-dawn / luci-app-statistics / ops tools) distilled from
  `reference/openwrt-ipq-redmi-ax6.config` (legacy qosmio main-nss era)

## Layout

```
├── .github/workflows/
│   ├── immortalwrt.yml      # x86-64 + jdcloud matrix
│   └── ppe-nss-redmi-ax6.yml # single device
├── configs/                 # active configuration (seeds + feed injections)
├── patches/feeds/           # feed patches (ported from the Builder)
├── scripts/prepare-build.sh # shared preparation script
└── reference/               # original source files (archive only, not built)
```

## Background: PPE vs NSS vs EDMA

The IPQ807x SoC has two parallel hardware acceleration paths plus one shared
transport:

- **EDMA** — the Ethernet DMA driver (the mover; every packet that needs the
  CPU passes through it; already in openwrt mainline)
- **PPE** — the switch-side flow-table engine (hardware forwarding/NAT, fully
  open source; in mainline since
  [PR #22381](https://github.com/openwrt/openwrt/pull/22381), with the
  flowtable/tc/switchdev offload interfaces landing via
  [PR #24806](https://github.com/openwrt/openwrt/pull/24806))
- **NSS** — dedicated acceleration cores + closed firmware blob (highest
  throughput ceiling). The vendor host stack (qca-nss-drv/ECM/NSS qdiscs)
  is archived; what survives is `nss-wifi-drv`, a small host driver that
  boots the firmware and hands it the ath11k rings — Wi-Fi data-path
  offload only, which is what this repo's AX6 line uses on top of the PPE

The Redmi AX6 serves as an AP: bridging and routed flows run in the PPE,
and the Wi-Fi data path runs on the NSS cores.

## Upstream References

- https://github.com/immortalwrt/immortalwrt — ImmortalWrt master
- https://github.com/JuliusBairaktaris/openwrt-ppe-nss — OpenWrt main + PPE
  drivers + NSS Wi-Fi offload (branch `ppe-nss`; the wiki's
  [Migrating from edma-nss](https://github.com/JuliusBairaktaris/openwrt-ppe-nss/wiki/Migrating-from-edma-nss)
  covers the old→new transition)
- https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder — reference
  implementation for the seed mode and the ppe-nss image recipe
  (`docs/CUSTOMIZE.md` is worth a read)
- https://github.com/JuliusBairaktaris/nss-packages — NSS firmware feed
  (branch `ppe-nss`), and
  [JuliusBairaktaris/luci](https://github.com/JuliusBairaktaris/luci)
  (branch `luci-app-ppe-qos`) standing in for the luci feed
- passwall feeds: see `configs/feeds.immortalwrt`

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
| Redmi AX6 | Wireless AP (NSS hardware offload) | [openwrt-nss-edma](https://github.com/JuliusBairaktaris/openwrt-nss-edma) `nss-edma-rework` | qualcommax/ipq807x | `configs/redmi-ax6-nss.seed` |

The Redmi AX6 NSS stack (toolchain optimizations, hardening options, the
full NSS kmod set, sqm-nss, luci-app-nss, …) is ported from the Builder's
`devices/common/config` + `ipq807x-512m` group (512 MB memory profile), and
`patches/feeds/luci/` carries its DSCP status-column patch. The Builder's
`ppe` material (PPE-only test line) does not apply to this repo.

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
  `immortalwrt-<device>-<date>` / `nss-redmi-ax6-<date>`), each release
  carries the final full `.config` (`config-full.defconfig`) and the seed it
  was built from, for traceability

The flashable file in each release is the `*-squashfs-sysupgrade.bin` (the
NSS line is sysupgrade-only — no factory/initramfs; you must already run
OpenWrt to flash it).

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
- `configs/redmi-ax6-nss.seed` — NSS stack aligned with the Builder's
  edma-nss variant; user picks (wpad-openssl / luci-app-dawn /
  luci-app-statistics / ops tools) distilled from
  `reference/openwrt-ipq-redmi-ax6.config` (legacy qosmio main-nss era)

## Layout

```
├── .github/workflows/
│   ├── immortalwrt.yml      # x86-64 + jdcloud matrix
│   └── nss-redmi-ax6.yml    # single device
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
  open source; the base driver is in mainline via
  [PR #22381](https://github.com/openwrt/openwrt/pull/22381), the full
  feature set is under review in
  [PR #24806](https://github.com/openwrt/openwrt/pull/24806))
- **NSS** — dedicated acceleration cores + closed firmware blob + ECM
  (highest throughput ceiling, includes Wi-Fi offload; the blob keeps it out
  of mainline forever — it lives on in forks like nss-edma, which is what
  this repo's NSS line uses)

The Redmi AX6 serves as an AP, and its main load is Wi-Fi↔Ethernet bridged
forwarding — exactly the scenario NSS (wifili) is best at.

## Upstream References

- https://github.com/immortalwrt/immortalwrt — ImmortalWrt master
- https://github.com/JuliusBairaktaris/openwrt-nss-edma — NSS fork (branch
  `nss-edma-rework`)
- https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder — reference
  implementation for the seed mode and the NSS stack (`docs/CUSTOMIZE.md`
  is worth a read)
- https://github.com/JuliusBairaktaris/nss-packages — NSS package feed
  (`edma-nss`)
- passwall feeds: see `configs/feeds.immortalwrt`

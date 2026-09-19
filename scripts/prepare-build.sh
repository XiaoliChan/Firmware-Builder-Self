#!/usr/bin/env bash
#
# 通用构建准备(仿 Qualcommax_NSS_Builder/scripts/prepare-build.sh):
#   1. feeds 文件逐行注入 feeds.conf(幂等,同名替换),逐个 update+install
#   2. seed → .config → make defconfig
#   3. 硬校验:seed 显式 =y 的符号必须存活(defconfig 静默丢弃 = 构建失败)
#   4. 禁用自定义 feed 的 CONFIG_FEED_*(不把整个 feed 打进固件 distfeeds)
#
# 用法: prepare-build.sh <seed 文件> <源码目录> [feeds 文件] [--prepend]
#   feeds 文件:每行一条 "src-git <name> <url>[;<branch>]"。默认追加到末尾;
#   --prepend 时插到头部(feed 越靠前优先级越高,保持文件内顺序)。
#
set -euo pipefail

SEED="$1"
SRC="$2"
FEEDS_FILE="${3:-}"
PREPEND="${4:-}"

cd "$SRC"

[[ -f "../$SEED" ]] || { echo "ERROR: seed 文件不存在: $SEED" >&2; exit 1; }
if [[ -n "$FEEDS_FILE" && ! -f "../$FEEDS_FILE" ]]; then
  echo "ERROR: feeds 文件不存在: $FEEDS_FILE" >&2
  exit 1
fi

mapfile -t FEED_LINES < <(grep -vE '^[[:space:]]*(#|$)' "../$FEEDS_FILE" 2>/dev/null || true)

# 1. 配置 feeds:操作副本 feeds.conf,不动 feeds.conf.default。
[[ -f feeds.conf ]] || cp feeds.conf.default feeds.conf
if ((${#FEED_LINES[@]})); then
  if [[ "$PREPEND" == "--prepend" ]]; then
    # 倒序逐行插到头部 → 最终文件内的第一行位于 feeds.conf 最顶部
    for ((i = ${#FEED_LINES[@]} - 1; i >= 0; i--)); do
      line="${FEED_LINES[$i]}"
      feed_name="$(awk '{print $2}' <<<"$line")"
      sed -i -E "/^src-\S+[[:space:]]+${feed_name}[[:space:]]/d" feeds.conf
      sed -i "1i ${line}" feeds.conf
    done
  else
    for line in "${FEED_LINES[@]}"; do
      feed_name="$(awk '{print $2}' <<<"$line")"
      if ! grep -qxF "$line" feeds.conf; then
        # 同名 feed 替换,防重复追加
        sed -i -E "/^src-\S+[[:space:]]+${feed_name}[[:space:]]/d" feeds.conf
        echo "$line" >>feeds.conf
      fi
    done
  fi
  echo "=== feeds.conf ==="
  cat feeds.conf

  # 逐个更新自定义 feed,失败立刻暴露
  for line in "${FEED_LINES[@]}"; do
    feed_name="$(awk '{print $2}' <<<"$line")"
    echo "=== update feed: $feed_name ==="
    ./scripts/feeds update "$feed_name"
    ./scripts/feeds install -a -p "$feed_name"
  done
fi

./scripts/feeds update -a
./scripts/feeds install -a

# 1b. 给 feed 包打补丁:仓库根 patches/feeds/<feed>/*.patch(路径相对 feed 根)。
#     --forward 未应用则打上;--reverse 已应用则跳过;都不行则构建失败。
shopt -s nullglob
for p in "../patches/feeds/"*/*.patch; do
  feed="$(basename "$(dirname "$p")")"
  if [[ ! -d "feeds/$feed" ]]; then
    echo "WARN: feeds/$feed 不存在,跳过 $(basename "$p")" >&2
    continue
  fi
  if patch -p1 -d "feeds/$feed" --dry-run --forward <"$p" >/dev/null 2>&1; then
    echo "=== patching feeds/$feed: $(basename "$p") ==="
    patch -p1 -d "feeds/$feed" --forward <"$p"
  elif patch -p1 -d "feeds/$feed" --dry-run --reverse <"$p" >/dev/null 2>&1; then
    echo "=== skip $(basename "$p") (already applied) ==="
  else
    echo "ERROR: $(basename "$p") does not apply to feeds/$feed" >&2
    exit 1
  fi
done
shopt -u nullglob

# 2. seed → .config → defconfig(依赖自动补全)
cp "../$SEED" .config
make defconfig

# 3. 校验:显式 =y 的符号必须出现在最终 .config。
#    Kconfig 对依赖不满足/改名的符号静默丢弃 —— 悄悄少包的固件比构建失败更糟。
#    只断言 =y:请求 =n 的符号被其他包依赖拉回是合法的。
dropped=()
while IFS= read -r req; do
  grep -qxF "$req" .config || dropped+=("$req")
done < <(grep -E '^CONFIG_[A-Za-z0-9_-]+=y$' "../$SEED")
if ((${#dropped[@]})); then
  echo "ERROR: defconfig 丢弃了 ${#dropped[@]} 个显式选择(符号改名或依赖缺失):" >&2
  printf '  %s\n' "${dropped[@]}" >&2
  exit 1
fi
echo "=== seed 符号校验通过 ==="

# 4. 自定义 feed 不打进固件 distfeeds(与官方默认同名的 fork stand-in 除外)。
if ((${#FEED_LINES[@]})); then
  for line in "${FEED_LINES[@]}"; do
    feed_name="$(awk '{print $2}' <<<"$line")"
    grep -qE "^src-\S+[[:space:]]+${feed_name}[[:space:]]" feeds.conf.default && continue
    sed -i "s/^CONFIG_FEED_${feed_name}=.*/# CONFIG_FEED_${feed_name} is not set/" .config || true
  done
fi
sed -i 's/^CONFIG_FEED_luci_extra=.*/# CONFIG_FEED_luci_extra is not set/' .config || true

echo "=== .config 摘要 ==="
grep -E '^CONFIG_TARGET_(BOARD|SUBTARGET|PROFILE)|PARTSIZE' .config || true
echo "=== 包数量 ==="
grep -c '^CONFIG_PACKAGE_.*=y' .config || true

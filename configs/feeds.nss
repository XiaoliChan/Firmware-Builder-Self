# 与 Qualcommax_NSS_Builder ppe-nss 线一致:
#   nss  — NSS 固件 feed(该分支只剩 nss-firmware 一个包)
#   luci — fork stand-in,替换默认 luci feed:带 luci-app-qca-ppe-qos(openwrt/luci PR 8965)
src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;ppe-nss
src-git luci https://github.com/JuliusBairaktaris/luci.git;luci-app-ppe-qos

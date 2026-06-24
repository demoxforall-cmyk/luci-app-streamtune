# luci-app-streamtune — оптимизация сетевого стека роутера под аудио-/видео-стриминг
# SPDX-License-Identifier: GPL-2.0
include $(TOPDIR)/rules.mk

LUCI_TITLE:=Stream Optimizer — tune network stack for low-latency audio streaming
# Рантайм-зависимости. Только luci-base жёстко обязателен. kmod-tcp-bbr и
# irqbalance — опциональные оптимизации; объявлены через LUCI_EXTRA_DEPENDS
# (форма без '+', версия >=0): при ОНЛАЙН-установке `apk add` сам докачает их из
# репозитория ImmortalWRT и они НЕ требуют сборки в SDK.
LUCI_DEPENDS:=+luci-base
LUCI_EXTRA_DEPENDS:=kmod-tcp-bbr, irqbalance
LUCI_PKGARCH:=all
PKG_VERSION:=1.0
PKG_LICENSE:=GPL-2.0
PKG_MAINTAINER:=StreamTune project

include $(TOPDIR)/feeds/luci/luci.mk

# ВАЖНО: бит исполнения на root/usr/libexec/rpcd/streamtune и
# root/etc/init.d/streamtune должен быть выставлен ДО сборки (на Windows бит x
# теряется). Сборочные обёртки build/*.sh делают chmod 0755 автоматически.

# call BuildPackage - OpenWrt buildroot signature

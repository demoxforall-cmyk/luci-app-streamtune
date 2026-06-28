# luci-app-streamtune — оптимизация сетевого стека роутера под аудио-/видео-стриминг
# SPDX-License-Identifier: GPL-2.0
include $(TOPDIR)/rules.mk

LUCI_TITLE:=Stream Optimizer — tune network stack for low-latency audio streaming
# Рантайм-зависимости. Только luci-base жёстко обязателен. kmod-tcp-bbr и
# irqbalance — опциональные оптимизации; объявлены через LUCI_EXTRA_DEPENDS
# (форма без '+', версия >=0): при ОНЛАЙН-установке `apk add` сам докачает их из
# репозитория ImmortalWRT и они НЕ требуют сборки в SDK.
LUCI_DEPENDS:=+luci-base
# kmod-tcp-bbr — профильный BBR; iputils-ping — DF-проба path MTU (BusyBox ping
# не умеет -M do; надёжнее tracepath при фильтрации ICMP на сотовых).
# irqbalance НЕ форсим (всегда OFF, детектится по факту).
LUCI_EXTRA_DEPENDS:=kmod-tcp-bbr (>=0), iputils-ping (>=0)
LUCI_PKGARCH:=all
PKG_VERSION:=2.8
PKG_LICENSE:=GPL-2.0
PKG_MAINTAINER:=StreamTune project

include $(TOPDIR)/feeds/luci/luci.mk

# ВАЖНО: бит исполнения на root/usr/libexec/rpcd/streamtune и
# root/etc/init.d/streamtune должен быть выставлен ДО сборки (на Windows бит x
# теряется). Сборочные обёртки build/*.sh делают chmod 0755 автоматически.

# call BuildPackage - OpenWrt buildroot signature

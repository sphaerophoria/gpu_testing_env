all: linux buildroot

LINUX_VERSION := 6.11
LINUX_TARBALL := download/linux-v$(LINUX_VERSION).tar.gz
LINUX_SRC := src/linux-$(LINUX_VERSION)

BUILDROOT_VERSION := 2024.08
BUILDROOT_TARBALL := download/buildroot-$(BUILDROOT_VERSION).tar.gz
BUILDROOT_SRC := src/buildroot-$(BUILDROOT_VERSION)

QEMU_VERSION := 9.1.0
QEMU_TARBALL := download/qemu-$(BUILDROOT_VERSION).tar.gz
QEMU_SRC := src/qemu-$(QEMU_VERSION)

BUSYBOX_VERSION := 1.37.0
BUSYBOX_TARBALL := download/busybox-$(BUILDROOT_VERSION).tar.bz2
BUSYBOX_SRC := src/busybox-$(BUSYBOX_VERSION)

CURDIR := $(PWD)

define do_download
	mkdir -p $(dir $@)
	curl -L -o $@ $(1)
endef

define do_extract
	mkdir -p $(dir $@)
	tar xf $< -C $(dir $@)
endef

$(LINUX_TARBALL):
	$(call do_download,https://github.com/torvalds/linux/archive/refs/tags/v$(LINUX_VERSION).tar.gz)

$(BUILDROOT_TARBALL):
	$(call do_download,https://www.buildroot.org/downloads/buildroot-$(BUILDROOT_VERSION).tar.gz)

$(QEMU_TARBALL):
	$(call do_download,https://download.qemu.org/qemu-9.1.0.tar.xz)

$(BUSYBOX_TARBALL):
	$(call do_download,https://busybox.net/downloads/busybox-1.37.0.tar.bz2)

$(BUILDROOT_SRC): $(BUILDROOT_TARBALL)
	$(call do_extract)

$(LINUX_SRC): $(LINUX_TARBALL)
	$(call do_extract)
	cd $@ && git init && git add . && git commit -m "Import linux $(LINUX_VERSION)" && git am $(CURDIR)/patch/linux/*

$(QEMU_SRC): $(QEMU_TARBALL)
	$(call do_extract)
	cd $@ && git init && git add . && git commit -m "Import qemu $(QEMU_VERSION)" && git am $(CURDIR)/patch/qemu/*

$(BUSYBOX_SRC): $(BUSYBOX_TARBALL)
	$(call do_extract)

buildroot: $(BUILDROOT_SRC)
	mkdir -p build/buildroot
	cp buildroot_config build/buildroot/.config
	$(MAKE) -C $< O=$(PWD)/build/buildroot

linux: $(LINUX_SRC)
	mkdir -p build/linux
	cp kernel_config build/linux/.config
	$(MAKE) -C $< O=$(PWD)/build/linux -j9

qemu: $(QEMU_SRC)
	mkdir -p build/qemu
	cd build/qemu && $(CURDIR)/$(QEMU_SRC)/configure
	ninja -C build/qemu qemu-system-x86_64

test_zig:
	cd test_app/ && zig build -p ../overlay/usr/

busybox: $(BUSYBOX_SRC)
	mkdir -p build/busybox
	cp busybox_config build/busybox/.config
	$(MAKE) -C $(BUSYBOX_SRC) O=$(CURDIR)/build/busybox CC=musl-gcc
	$(MAKE) -C $(BUSYBOX_SRC) O=$(CURDIR)/build/busybox CC=musl-gcc install CONFIG_PREFIX=$(CURDIR)/build/ramdisk

.PHONY: busybox buildroot linux test_zig qemu

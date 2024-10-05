all:

download:
	mkdir -p download

LINUX_VERSION := 6.11
LINUX_TARBALL := download/linux-v$(LINUX_VERSION).tar.gz
LINUX_SRC := src/linux-$(LINUX_VERSION)

BUILDROOT_VERSION := 2024.08
BUILDROOT_TARBALL := download/buildroot-$(BUILDROOT_VERSION).tar.gz
BUILDROOT_SRC := src/buildroot-$(BUILDROOT_VERSION)

QEMU_VERSION := 9.1.0
QEMU_TARBALL := download/qemu-$(BUILDROOT_VERSION).tar.gz
QEMU_SRC := src/qemu-$(QEMU_VERSION)

CURDIR := $(PWD)

define do_download
	curl -L -o $@ $(1)
endef

define do_extract
	mkdir -p $(dir $@)
	tar xf $< -C $(dir $@)
endef

$(LINUX_TARBALL): download
	$(call do_download,https://github.com/torvalds/linux/archive/refs/tags/v$(LINUX_VERSION).tar.gz)

$(BUILDROOT_TARBALL): download
	$(call do_download,https://www.buildroot.org/downloads/buildroot-$(BUILDROOT_VERSION).tar.gz)

$(QEMU_TARBALL): download
	$(call do_download,https://download.qemu.org/qemu-9.1.0.tar.xz)

$(BUILDROOT_SRC): $(BUILDROOT_TARBALL)
	$(call do_extract)

$(LINUX_SRC): $(LINUX_TARBALL)
	$(call do_extract)
	cd $@ && git init && git add . && git commit -m "Import linux $(LINUX_VERSION)" && git am $(CURDIR)/patch/linux/*

$(QEMU_SRC): $(QEMU_TARBALL)
	$(call do_extract)
	cd $@ && git init && git add . && git commit -m "Import qemu $(QEMU_VERSION)" && git am $(CURDIR)/patch/qemu/*

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

test_zig:
	cd test_app/ && zig build -p ../overlay/usr/

.PHONY: buildroot linux test_zig

all: linux buildroot

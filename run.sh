#!/usr/bin/env bash

pushd $(dirname $0)

cp build/linux/drivers/gpu/drm/sphaero/sphaero-gpu.ko build/ramdisk/

pushd build/ramdisk
find . | cpio --quiet -H newc -o | gzip >  ../ramdisk.cpio.gz
popd

gdb --args ./build/qemu/qemu-system-x86_64 -initrd ./build/ramdisk.cpio.gz -kernel ./build/linux/arch/x86/boot/bzImage -append "root=/dev/vda console=ttyS0 nokaslr ip=dhcp" -drive format=raw,file=build/buildroot/images/rootfs.ext2,if=virtio -m 1024M -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22 -device virtio-gpu-gl -display gtk,gl=core -device sphaero

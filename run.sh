#!/usr/bin/env bash

qemu-system-x86_64 -enable-kvm -cpu host -kernel ./build/linux/arch/x86/boot/bzImage -append "root=/dev/vda" --enable-kvm -drive format=raw,file=build/buildroot/images/rootfs.ext2,if=virtio -vga qxl -m 1024M -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22


#!/usr/bin/env bash

./build/qemu/qemu-system-x86_64 -enable-kvm -cpu host -kernel ./build/linux/arch/x86/boot/bzImage -append "root=/dev/vda console=ttyS0" --enable-kvm -drive format=raw,file=build/buildroot/images/rootfs.ext2,if=virtio -m 1024M -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22 -device virtio-gpu-gl -display gtk,gl=on


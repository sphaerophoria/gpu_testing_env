# A virtual GPU

This repo consists of...

* A library that implements a virtual GPU
* A set of patches to qemu to use the gpu library in a PCI device
* A set of patches to the linux kernel to use the qemu PCI device
* A set of patches to mesa to use the linux kernel driver

This is a playground for experimenting with such a system. Please note that the
goal of this is not to create a robust piece of maintainable software, but to
learn about how a GPU functions

The build process here is pretty messy. I would view the Makefile as a
suggestion as I'm not sure it will work in other places. I also am not sure how
well it works for anything other than initial project setup. My workflow after
initial build involved a lot of manual subproject building + scp

The Makefile will
* Download the relevant projects
* Init a git repo for qemu/linux/mesa and apply the appropriate patches
* Create a userspace with buildroot
  * This could probably be stripped down a ton, but I didn't, enjoy the year long build time
* Build busybox for a ramdisk

Trying to build all projects at once probably won't work. In my nix environment
I can't build qemu in the same shell as everything else.

My build/run process is as follows

```
nix-shell
make -j<whatever> # for buildroot + linux

cd libgpu
zig build -Doptimize=ReleaseSafe

cd ..
nvim cross-compilation.conf # Fix hardcoded paths
make mesa

exit

nix-shell busybox_shell.nix
make -j<whatever> busybox

exit

nix-shell qemu_shell.nix
make qemu

exit

./run.sh &

# Update OpenGL libs in VM
scp -P 5555 build/mesa/src/egl/libEGL.so.1.0.0 root@localhost:/usr/lib/libEGL.so.1.0.0  && scp -P 5555 build/mesa/src/gbm/libgbm.so.1.0.0 root@localhost:/usr/lib/libgbm.so.1.0.0 && scp -P 5555 build/mesa/src/gallium/targets/dri/libgallium_dri.so root@localhost:/usr/lib/dri/virtio_gpu_dri.so && scp -P 5555 build/mesa/src/gallium/targets/dri/libgallium_dri.so root@localhost:/usr/lib/dri/sphaero_gpu_dri.so &&  scp -P 5555 build/mesa/src/gbm/libgbm.so.1.0.0 root@localhost:/usr/lib64/libgbm.so.1.0.0


nix-shell
cd test_app
# Upload test_app and run it
zig build && scp -P 5555 zig-out/bin/test_app root@localhost:/ && ssh -p 5555 root@localhost env /test_app /dev/dri/card1


```



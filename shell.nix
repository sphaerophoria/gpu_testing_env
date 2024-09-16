let
  pkgs = import <nixpkgs> { };
  unstable = import
    (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/8001cc402f61b8fd6516913a57ec94382455f5e5.tar.gz")
    # reuse the current configuration
    { config = pkgs.config; };
in
(pkgs.buildFHSUserEnv {
  name = "kernel-build-env";
  targetPkgs = pkgs: (with pkgs;
    [
      pkg-config
      ncurses.dev
      qemu
      musl.dev
      file
      wget
      libxcrypt
      clang-tools
    ]
    ++ pkgs.linux.nativeBuildInputs);
}).env

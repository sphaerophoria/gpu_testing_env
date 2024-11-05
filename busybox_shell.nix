with import <nixpkgs> { };
(pkgs.buildFHSUserEnv {
  name = "busybox-build-env";
  targetPkgs = pkgs: (with pkgs; [
      pkg-config
      ncurses.dev
      musl.dev
  ]);
}).env

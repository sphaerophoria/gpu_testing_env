with import <nixpkgs> {};

pkgs.mkShell {
	nativeBuildInputs = [
		clang-tools
		gdb
	] ++ pkgs.qemu.nativeBuildInputs;
	buildInputs = pkgs.qemu.buildInputs;
}

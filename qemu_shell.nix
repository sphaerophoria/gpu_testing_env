with import <nixpkgs> {};

pkgs.mkShell {
	nativeBuildInputs = [
		clang-tools
	] ++ pkgs.qemu.nativeBuildInputs;
	buildInputs = pkgs.qemu.buildInputs;
}

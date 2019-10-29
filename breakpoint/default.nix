{ stdenv, pkgs }:

stdenv.mkDerivation {
  pname = "hello";
  version = "0.0.1";

  src = ./.;
  nativeBuildInputs = [ pkgs.unixtools.ping pkgs.breakpointHook ];

  installPhase = ''
	mkdir -p $out/bin
    cp hello $out/bin
  '';
}

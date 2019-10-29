{ stdenv }:

stdenv.mkDerivation {
  pname = "hello";
  version = "0.0.1";

  src = ./.;

  installPhase = ''
	mkdir -p $out/bin
    cp hello $out/bin
  '';
}

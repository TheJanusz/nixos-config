{
  lib,
  stdenvNoCC,
  python3,
  makeWrapper,
}:

let
  python = python3.withPackages (ps: [
    ps.opencv4
    ps.numpy
  ]);
in
stdenvNoCC.mkDerivation {
  pname = "discflat";
  version = "0.1.0";
  src = ./.;

  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/discflat $out/bin
    cp discflat.py $out/lib/discflat/
    makeWrapper ${python}/bin/python $out/bin/discflat \
      --add-flags "$out/lib/discflat/discflat.py"
    runHook postInstall
  '';

  meta = {
    description = "Detect a disc in a photo, rectify to a circle, write a square transparent PNG";
    mainProgram = "discflat";
    license = lib.licenses.mit;
  };
}

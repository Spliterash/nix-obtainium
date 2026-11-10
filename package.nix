# The plugin must be built against the exact Nix it is loaded into (no stable ABI),
# so `nix` is the target Nix package, e.g. config.nix.package.
{
  lib,
  stdenv,
  pkg-config,
  nlohmann_json,
  symlinkJoin,
  writers,
  nix,
  connectors ? [ ],
}:
let
  connector-github = writers.writePython3Bin "nix-obtainium-github" { doCheck = false; } (
    builtins.readFile ./connectors/github.py
  );
  allConnectors = symlinkJoin {
    name = "nix-obtainium-connectors";
    paths = [ connector-github ] ++ connectors;
  };
in
assert lib.assertMsg (nix ? libs) "nix-obtainium: '${nix.name}' has no .libs, only nixpkgs' CppNix is supported";
stdenv.mkDerivation {
  pname = "nix-obtainium";
  version = "0.1.0";
  src = ./plugin;
  nativeBuildInputs = [ pkg-config ];
  buildInputs = with nix.libs; [
    nix-fetchers
    nix-store
    nix-util
    nlohmann_json
  ];
  buildPhase = ''
    $CXX -std=c++23 -shared -fPIC -O2 -o libnix-obtainium.so release.cc \
      -DNIX_OBTAINIUM_CONNECTORS='"${allConnectors}/bin"' \
      $(pkg-config --cflags --libs nix-fetchers nix-store nix-util)
  '';
  installPhase = "install -Dm755 libnix-obtainium.so $out/lib/libnix-obtainium.so";
  passthru = { inherit connector-github; };
}

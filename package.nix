# The plugin must be built against the exact Nix it is loaded into (no stable ABI),
# so `nix` is the target Nix package, e.g. config.nix.package.
{
  lib,
  stdenv,
  pkg-config,
  nlohmann_json,
  symlinkJoin,
  makeWrapper,
  writers,
  nix,
  connectors ? [ ],
}:
let
  connector-github = writers.writePython3Bin "nix-obtainium-github" { flakeIgnore = [ "E501" ]; } (
    builtins.readFile ./connectors/github.py
  );
  allConnectors = symlinkJoin {
    name = "nix-obtainium-connectors";
    paths = [ connector-github ] ++ connectors;
  };
in
assert lib.assertMsg (nix ? libs) "nix-obtainium: '${nix.name}' has no .libs, only nixpkgs' CppNix is supported";
stdenv.mkDerivation (finalAttrs: {
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
    runHook preBuild
    $CXX -std=c++23 -shared -fPIC -O2 -o libnix-obtainium.so obtainium.cc \
      -DNIX_MINOR=${lib.versions.minor nix.version} \
      -DNIX_OBTAINIUM_CONNECTORS='"${allConnectors}/bin"' \
      $(pkg-config --cflags --libs nix-fetchers nix-store nix-util)
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 libnix-obtainium.so $out/lib/libnix-obtainium.so
    runHook postInstall
  '';
  passthru = {
    inherit connector-github;
    # Plugin is passed only to this nix, not via nix.conf: any other nix (e.g. from a devShell) would load it and crash.
    nix = symlinkJoin {
      name = "nix-with-obtainium";
      paths = [ nix ];
      nativeBuildInputs = [ makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/nix --add-flags "--option plugin-files ${finalAttrs.finalPackage}/lib/libnix-obtainium.so"
      '';
    };
  };

  meta = {
    description = "Nix plugin: flake inputs that lock the latest release asset and update with nix flake update";
    homepage = "https://github.com/Spliterash/nix-obtainium";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
})

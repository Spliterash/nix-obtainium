{
  lib,
  stdenv,
  src,
  version,
  dpkg,
  autoPatchelfHook,
  libx11,
  libxcb,
  libxcursor,
  libxi,
  libxkbcommon,
  vulkan-loader,
  wayland,
}:

stdenv.mkDerivation {
  pname = "photocraft";
  inherit src version;

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
  ];
  buildInputs = [ stdenv.cc.cc.lib ];

  # Loaded with dlopen by winit/wgpu, so autoPatchelf can't see them in NEEDED.
  runtimeDependencies = [
    libx11
    libxcb
    libxcursor
    libxi
    libxkbcommon
    vulkan-loader
    wayland
  ];

  # The input is stored as "source" without the .deb extension, so dpkg's hook skips it.
  unpackCmd = "dpkg -x $curSrc root";
  sourceRoot = "root";

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r usr/bin usr/share $out/
    runHook postInstall
  '';

  meta = {
    description = "Open-source photo editor written in Rust";
    homepage = "https://github.com/storytold/photocraft";
    license = with lib.licenses; [
      mit
      asl20
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "photocraft";
  };
}

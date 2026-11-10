obtainiumLib:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nix.obtainium;
in
{
  options.nix.obtainium = {
    enable = lib.mkEnableOption "nix-obtainium plugin (file+https://nix-obtainium.invalid/... flake inputs)";
    connectors = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra connectors: packages providing bin/nix-obtainium-<name>. GitHub is built in.";
    };
    flake = lib.mkOption {
      type = lib.types.nullOr lib.types.raw;
      default = null;
      example = lib.literalExpression "self";
      description = "Your flake. Its nix-obtainium inputs become pkgs.obtainium.<input> = { src, version, fileName, url }.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = pkgs.callPackage ./package.nix {
        nix = config.nix.package;
        inherit (cfg) connectors;
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      nix.settings.plugin-files = [ "${cfg.package}/lib/libnix-obtainium.so" ];
    })
    (lib.mkIf (cfg.flake != null) {
      nixpkgs.overlays = [ (_: _: { obtainium = obtainiumLib.releases cfg.flake; }) ];
    })
  ];
}

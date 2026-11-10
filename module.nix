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
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = pkgs.callPackage ./package.nix {
        nix = config.nix.package;
        inherit (cfg) connectors;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings.plugin-files = [ "${cfg.package}/lib/libnix-obtainium.so" ];
  };
}

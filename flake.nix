{
  description = "Obtainium-like flake inputs: lock the latest release asset, update with nix flake update";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    {
      nixosModules.default = import ./module.nix self.lib;

      # Flake inputs only expose outPath/narHash, so release info is read from the lock:
      # lib.release self "gh" -> { version = "2.103.3"; fileName = "gh_2.103.3_linux_amd64.deb"; url = "..."; }
      lib.release =
        flake: input:
        let
          lock = builtins.fromJSON (builtins.readFile "${flake}/flake.lock");
          parts = builtins.match "([^#]*)#(.*)" lock.nodes.${lock.nodes.root.inputs.${input}}.locked.url;
        in
        if parts == null then
          throw "nix-obtainium: input '${input}' is not locked by nix-obtainium"
        else
          {
            url = builtins.elemAt parts 0;
            version = builtins.elemAt parts 1;
            fileName = baseNameOf (builtins.elemAt parts 0);
          };

      # All nix-obtainium inputs of a flake: lib.releases self -> { gh = { src; version; fileName; url; }; }
      lib.releases =
        flake:
        let
          lock = builtins.fromJSON (builtins.readFile "${flake}/flake.lock");
          root = lock.nodes.root.inputs;
          isObtainium =
            name:
            builtins.isString root.${name}
            && builtins.match ".*//nix-obtainium\\.invalid/.*" (lock.nodes.${root.${name}}.original.url or "") != null;
        in
        builtins.listToAttrs (
          map (name: {
            inherit name;
            value = self.lib.release flake name // {
              src = flake.inputs.${name};
            };
          }) (builtins.filter isObtainium (builtins.attrNames root))
        );

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          plugin = pkgs.callPackage ./package.nix { nix = pkgs.nix; };
        in
        {
          default = plugin;
          inherit (plugin) connector-github;

          # Bootstrap: `nix shell <this flake>#nix -c nix flake update` on a system without the plugin.
          nix = pkgs.symlinkJoin {
            name = "nix-with-obtainium";
            paths = [ pkgs.nix ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              wrapProgram $out/bin/nix --add-flags "--option plugin-files ${plugin}/lib/libnix-obtainium.so"
            '';
          };
        }
      );
    };
}

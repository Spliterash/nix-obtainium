{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-obtainium = {
      url = "github:Spliterash/nix-obtainium";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    photocraft = {
      url = "file+https://nix-obtainium.invalid/github/storytold/photocraft?asset=photocraft-*-linux-x86_64.deb";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-obtainium,
      photocraft,
    }:
    {
      packages.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.callPackage ./package.nix {
        src = photocraft;
        inherit (nix-obtainium.lib.release self "photocraft") version;
      };
    };
}

# nix-obtainium

**English** | [Русский](README.ru.md)

A Nix plugin in the spirit of [Obtainium](https://github.com/ImranR98/Obtainium): flake inputs that point to the
**latest release** (GitHub releases or your own source), are pinned in `flake.lock` and updated with a plain
`nix flake update`.

```nix
inputs.photocraft = {
  url = "file+https://nix-obtainium.invalid/github/storytold/photocraft?asset=photocraft-*-linux-x86_64.deb";
  flake = false;
};
```

After `nix flake update` the lock contains an ordinary `file` input:

```json
"locked": {
  "type": "file",
  "url": "https://github.com/storytold/photocraft/releases/download/v0.22.0/photocraft-0.22.0-linux-x86_64.deb#0.22.0",
  "narHash": "sha256-9+P/gImaCLoh/eKcrUYyXcM8vsgm9hsSwqG8bJCr9IY="
}
```

## How it works

- The plugin intercepts URLs with the host `nix-obtainium.invalid`, calls a connector (the first path segment),
  gets the real URL and version, downloads the file and locks it as a plain `type = "file"`.
- The version is stored in the URL fragment (`#0.22.0`): curl never sends it, and the lock has no other place for it.
- **The plugin is only needed for updating.** Building from an existing lock works with any Nix without the plugin,
  including installing a system from a fresh ISO (`nixos-install --flake`).
- Without the plugin `nix flake update` fails with `Could not resolve host: nix-obtainium.invalid` and leaves the
  lock untouched. `.invalid` domains never resolve (RFC 2606).

Internally the plugin is an `InputScheme` registered ahead of the builtin `file` scheme (Nix tries schemes in
alphabetical order). This is Nix internals, not a public API, so run `tests/run.sh` after upgrading Nix.

## Example: photocraft on NixOS

Installing [photocraft](https://github.com/storytold/photocraft) from the `.deb` of its latest GitHub release.

`flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-obtainium = {
      url = "github:Spliterash/nix-obtainium";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Latest release; the version is pinned in flake.lock and updated by nix flake update
    photocraft = {
      url = "file+https://nix-obtainium.invalid/github/storytold/photocraft?asset=photocraft-*-linux-x86_64.deb";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, nix-obtainium, ... }:
    {
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
          nix-obtainium.nixosModules.default
          (
            { pkgs, ... }:
            {
              nix.obtainium = {
                enable = true; # plugin for nix flake update
                flake = self;  # obtainium inputs of this flake -> pkgs.obtainium.<input>
              };
              environment.systemPackages = [ (pkgs.callPackage ./photocraft.nix { }) ];
            }
          )
        ];
      };
    };
}
```

`photocraft.nix` is a regular package that takes only `src` and `version` from `obtainium`:

```nix
{
  stdenv,
  obtainium,
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
  inherit (obtainium.photocraft) src version;

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
  ];
  buildInputs = [ stdenv.cc.cc.lib ];

  # Loaded with dlopen by winit/wgpu, so autoPatchelf can't see them in NEEDED
  runtimeDependencies = [
    libx11
    libxcb
    libxcursor
    libxi
    libxkbcommon
    vulkan-loader
    wayland
  ];

  # The input is stored as "source" without the .deb extension, so dpkg's hook skips it
  unpackCmd = "dpkg -x $curSrc root";
  sourceRoot = "root";

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r usr/bin usr/share $out/
    runHook postInstall
  '';
}
```

`pkgs.obtainium.photocraft` looks like this:

```nix
{
  src = <the .deb file in the store>;
  version = "0.22.0";
  fileName = "photocraft-0.22.0-linux-x86_64.deb";
  url = "https://github.com/storytold/photocraft/releases/download/v0.22.0/photocraft-0.22.0-linux-x86_64.deb";
}
```

The first time (the plugin is not in the system yet), lock with the Nix from this flake, then as usual:

```sh
nix shell github:Spliterash/nix-obtainium#nix -c nix flake lock
sudo nixos-rebuild switch --flake .#myhost

# later, with the plugin in the system:
nix flake update && sudo nixos-rebuild switch --flake .#myhost
```

A new app is just an input in `flake.nix` and a package with `inherit (obtainium.<input>) src version;`.

### What the module does

- Builds the plugin against `config.nix.package` (the plugin has no stable ABI, versions must match) and adds it
  to `nix.settings.plugin-files`. Only CppNix from nixpkgs is supported: Lix and Determinate Nix have different
  internals.
- With `flake = self`, adds an overlay with `pkgs.obtainium`: every input of the flake using `nix-obtainium.invalid`.

Without the plugin, everything except the nix-obtainium inputs can be updated with plain Nix:

```sh
nix flake update $(jq -r '.nodes as $n | $n.root.inputs | to_entries[]
  | select(.value | type == "string")
  | select($n[.value].original.url // "" | contains("nix-obtainium.invalid") | not) | .key' flake.lock)
```

### Without NixOS

The same set is available as `nix-obtainium.lib.releases self`, a single input as
`nix-obtainium.lib.release self "photocraft"` (without `src`):

```nix
packages.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.callPackage ./photocraft.nix {
  obtainium = nix-obtainium.lib.releases self;
};
```

Working flake: [`examples/photocraft`](examples/photocraft).

### Packaging notes

- The file in the store is named `source` (a flake input can't be given a name), so hooks that detect the format
  by extension skip it: unpack `.deb` explicitly, as above.
- An executable comes without the `+x` bit: `install -Dm755 ${src} $out/bin/app`.

## GitHub connector

```
file+https://nix-obtainium.invalid/github/<owner>/<repo>?asset=<glob>[&tag=<glob>][&prerelease=1]
```

| Parameter    | Meaning                                                          |
|--------------|------------------------------------------------------------------|
| `asset`      | asset name glob, required: `app_*_amd64.deb`                     |
| `tag`        | tag glob, `*` by default; `tag=v1.3.*` sticks to a version line  |
| `prerelease` | `1` — consider prereleases                                       |

The newest release whose tag and an asset match is taken. The version is the tag without a leading `v`.

Downloads need no token. A token only helps against the GitHub API rate limit (60 requests per hour without one):
it is taken from `access-tokens` for `github.com` in the Nix settings or from `GITHUB_TOKEN`.

## Custom connector

A connector is an executable `bin/nix-obtainium-<name>` in any language. The plugin only sees connectors baked
into it at build time, so they are pinned by the system's lock file like everything else:

```nix
nix.obtainium.connectors = [ (pkgs.writers.writePython3Bin "nix-obtainium-mysrc" { } ./mysrc.py) ];
```

The URL `file+https://nix-obtainium.invalid/mysrc/a/b?x=1` calls `nix-obtainium-mysrc`. The protocol is JSON:

```
stdin:  {"path": ["a", "b"], "query": {"x": "1"}, "accessTokens": {"github.com": "..."}}
stdout: {"version": "1.2.3", "url": "https://example.com/files/app-1.2.3.tar.gz"}
```

A non-zero exit code is an error, stderr is shown to the user. Downloading, hashing and writing the lock are done
by the plugin. The returned URL must be immutable: builds from the lock will fetch it.

## Test

```sh
nix shell nixpkgs#jq -c tests/run.sh
```

Requires network: the test uses the real GitHub (`cli/cli`) and checks locking, `lib.release`, building without
the plugin on an empty store, the `tag` filter, behaviour without the plugin and an unknown connector.

## License

[MIT](LICENSE)

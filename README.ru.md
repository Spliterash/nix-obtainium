# nix-obtainium

[English](README.md) | **Русский**

[![AI Slop Inside](https://sladge.net/badge.svg)](https://sladge.net)

Плагин Nix в духе [Obtainium](https://github.com/ImranR98/Obtainium): входы флейка, которые указывают на
**последний релиз** (GitHub releases или свой источник), фиксируются в `flake.lock` и обновляются обычным
`nix flake update`.

```nix
inputs.photocraft = {
  url = "file+https://nix-obtainium.invalid/github/storytold/photocraft?asset=photocraft-*-linux-x86_64.deb";
  flake = false;
};
```

После `nix flake update` в lock лежит обычный вход типа `file`:

```json
"locked": {
  "type": "file",
  "url": "https://github.com/storytold/photocraft/releases/download/v0.22.0/photocraft-0.22.0-linux-x86_64.deb#0.22.0",
  "narHash": "sha256-9+P/gImaCLoh/eKcrUYyXcM8vsgm9hsSwqG8bJCr9IY="
}
```

## Как это работает

- Плагин перехватывает URL с хостом `nix-obtainium.invalid`, вызывает коннектор (первый сегмент пути),
  получает реальный URL и версию, скачивает файл и фиксирует его как обычный `type = "file"`.
- Версия хранится во фрагменте URL (`#0.22.0`): curl его не отправляет, а другого места в lock нет.
- **Плагин нужен только для обновления.** Сборка по готовому lock работает в любом Nix без плагина,
  в том числе установка системы с чистого ISO (`nixos-install --flake`).
- Без плагина `nix flake update` падает с `Could not resolve host: nix-obtainium.invalid` и lock не трогает.
  Домены `.invalid` не резолвятся никогда (RFC 2606).

Плагин внутри — `InputScheme`, которая регистрируется раньше встроенной `file` (Nix перебирает схемы по
алфавиту). Это внутреннее устройство Nix, а не публичный API, поэтому после обновления Nix стоит прогнать
`tests/run.sh`.

## Пример: photocraft в NixOS

Ставим [photocraft](https://github.com/storytold/photocraft) из `.deb` последнего релиза на GitHub.

`flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-obtainium = {
      url = "github:Spliterash/nix-obtainium";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Последний релиз; версия фиксируется в flake.lock, обновляется через nix flake update
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
                enable = true; # плагин для nix flake update
                flake = self;  # obtainium-входы этого флейка -> pkgs.obtainium.<вход>
              };
              environment.systemPackages = [ (pkgs.callPackage ./photocraft.nix { }) ];
            }
          )
        ];
      };
    };
}
```

`photocraft.nix` — обычный пакет, только `src` и `version` берёт из `obtainium`:

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

  # winit/wgpu грузят их через dlopen, autoPatchelf их в NEEDED не видит
  runtimeDependencies = [
    libx11
    libxcb
    libxcursor
    libxi
    libxkbcommon
    vulkan-loader
    wayland
  ];

  # Вход лежит в store как "source" без расширения .deb, хук dpkg его не узнаёт
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

`pkgs.obtainium.photocraft` выглядит так:

```nix
{
  src = <файл .deb в store>;
  version = "0.22.0";
  fileName = "photocraft-0.22.0-linux-x86_64.deb";
  url = "https://github.com/storytold/photocraft/releases/download/v0.22.0/photocraft-0.22.0-linux-x86_64.deb";
}
```

Первый раз (плагина в системе ещё нет) — lock через Nix из этого флейка, дальше как обычно:

```sh
nix shell github:Spliterash/nix-obtainium#nix -c nix flake lock
sudo nixos-rebuild switch --flake .#myhost

# потом, уже с плагином в системе:
nix flake update && sudo nixos-rebuild switch --flake .#myhost
```

Новое приложение — это вход во `flake.nix` и пакет с `inherit (obtainium.<вход>) src version;`.

### Что делает модуль

- Собирает плагин против `config.nix.package` (у плагина нет стабильного ABI, версии обязаны совпадать)
  и прописывает его в `nix.settings.plugin-files`. Поддерживается только CppNix из nixpkgs: у Lix и
  Determinate Nix свои внутренности.
- С `flake = self` добавляет overlay с `pkgs.obtainium`: все входы флейка с `nix-obtainium.invalid`.

Без плагина обновить всё, кроме входов nix-obtainium, можно обычным Nix:

```sh
nix flake update $(jq -r '.nodes as $n | $n.root.inputs | to_entries[]
  | select(.value | type == "string")
  | select($n[.value].original.url // "" | contains("nix-obtainium.invalid") | not) | .key' flake.lock)
```

### Без NixOS

Тот же набор даёт `nix-obtainium.lib.releases self`, один вход — `nix-obtainium.lib.release self "photocraft"`
(без `src`):

```nix
packages.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.callPackage ./photocraft.nix {
  obtainium = nix-obtainium.lib.releases self;
};
```

Рабочий флейк — [`examples/photocraft`](examples/photocraft).

### Что учесть при упаковке

- Файл в store называется `source` (имя у флейк-входа задать нельзя), поэтому хуки, которые узнают формат
  по расширению, его пропускают: `.deb` распаковывать явно, как выше.
- Исполняемый файл приходит без бита `+x`: `install -Dm755 ${src} $out/bin/app`.

## Коннектор GitHub

```
file+https://nix-obtainium.invalid/github/<owner>/<repo>?asset=<glob>[&tag=<glob>][&prerelease=1]
```

| Параметр     | Назначение                                                        |
|--------------|-------------------------------------------------------------------|
| `asset`      | glob имени ассета, обязателен: `app_*_amd64.deb`                  |
| `tag`        | glob тега, по умолчанию `*`; `tag=v1.3.*` держит ветку версий     |
| `prerelease` | `1` — учитывать пререлизы                                         |

Берётся самый новый релиз, у которого совпали тег и ассет. Версия — тег без ведущего `v`.

Скачивание идёт без токена. Токен нужен только против лимита GitHub API (60 запросов в час без него):
берётся из `access-tokens` для `github.com` в настройках Nix или из `GITHUB_TOKEN`.

## Свой коннектор

Коннектор — исполняемый файл `bin/nix-obtainium-<имя>`, язык любой. Плагин видит только коннекторы,
вшитые в него при сборке, поэтому они зафиксированы lock-файлом системы, как всё остальное:

```nix
nix.obtainium.connectors = [ (pkgs.writers.writePython3Bin "nix-obtainium-mysrc" { } ./mysrc.py) ];
```

URL `file+https://nix-obtainium.invalid/mysrc/a/b?x=1` вызывает `nix-obtainium-mysrc`. Протокол — JSON:

```
stdin:  {"path": ["a", "b"], "query": {"x": "1"}, "accessTokens": {"github.com": "..."}}
stdout: {"version": "1.2.3", "url": "https://example.com/files/app-1.2.3.tar.gz"}
```

Ненулевой код выхода — ошибка, stderr показывается пользователю. Скачивание, хеш и запись в lock делает
плагин. Возвращаемый URL должен быть неизменяемым: по нему будут собирать по lock.

## Тест

```sh
nix shell nixpkgs#jq -c tests/run.sh
```

Нужна сеть: тест ходит в реальный GitHub (`cli/cli`) и проверяет фиксацию, `lib.release`, сборку без
плагина на пустом store, фильтр `tag`, поведение без плагина и неизвестный коннектор.

## Лицензия

[MIT](LICENSE)

# nix-obtainium

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

## Подключение (NixOS)

```nix
# flake.nix
inputs.nix-obtainium = {
  url = "github:Spliterash/nix-obtainium";
  inputs.nixpkgs.follows = "nixpkgs";
};

# конфигурация системы
imports = [ inputs.nix-obtainium.nixosModules.default ];
nix.obtainium = {
  enable = true;  # плагин для nix flake update
  flake = self;   # obtainium-входы флейка -> pkgs.obtainium.<вход>
};
```

Модуль собирает плагин против `config.nix.package` (у плагина нет стабильного ABI, версии обязаны совпадать)
и прописывает его в `nix.settings.plugin-files`. Поддерживается только CppNix из nixpkgs: у Lix и Determinate
Nix свои внутренности.

### Первый запуск

Пока система не пересобрана с модулем, плагина нет. Для обновления lock используй Nix из этого флейка:

```sh
nix shell github:Spliterash/nix-obtainium#nix -c nix flake update
```

Или обнови всё, кроме входов nix-obtainium, обычным Nix:

```sh
nix flake update $(jq -r '.nodes as $n | $n.root.inputs | to_entries[]
  | select(.value | type == "string")
  | select($n[.value].original.url // "" | contains("nix-obtainium.invalid") | not) | .key' flake.lock)
```

## Использование в пакете

Вход даёт **только файл** (`outPath` — сам `.deb`/бинарник/архив), что с ним делать — решает пакет.
С `nix.obtainium.flake = self` все obtainium-входы доступны пакетам как `pkgs.obtainium.<вход>`:

```nix
# pkgs.obtainium.photocraft
# -> { src = <файл>; version = "0.22.0"; fileName = "photocraft-0.22.0-linux-x86_64.deb"; url = "https://..."; }

# photocraft.nix — подключается обычным callPackage ./photocraft.nix { }
{ stdenv, obtainium, dpkg, ... }:
stdenv.mkDerivation {
  pname = "photocraft";
  inherit (obtainium.photocraft) src version;
  # ...
}
```

Вне NixOS тот же набор даёт `nix-obtainium.lib.releases self`
(`callPackage ./package.nix { obtainium = nix-obtainium.lib.releases self; }`),
а для одного входа — `nix-obtainium.lib.release self "photocraft"` (без `src`).

Полный пример — [`examples/photocraft`](examples/photocraft): `.deb` из GitHub releases,
распаковка, `autoPatchelfHook` и библиотеки, которые приложение грузит через dlopen.

```sh
cd examples/photocraft
nix flake update   # с плагином: зафиксирует последний релиз
nix build
```

Что учесть при упаковке:

- Файл в store называется `source` (имя у флейк-входа задать нельзя), поэтому хуки, которые узнают формат
  по расширению, его пропускают. `.deb` распаковывать явно: `unpackCmd = "dpkg -x $curSrc root";`.
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

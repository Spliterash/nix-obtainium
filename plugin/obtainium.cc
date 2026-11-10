#include "nix/fetchers/fetchers.hh"
#include "nix/fetchers/fetch-settings.hh"
#include "nix/fetchers/tarball.hh"
#include "nix/store/store-api.hh"
#include "nix/util/processes.hh"
#include "nix/util/url.hh"

#include <nlohmann/json.hpp>
#include <unistd.h>

using namespace nix;
using namespace nix::fetchers;

static constexpr std::string_view obtainiumHost = "nix-obtainium.invalid";

static const InputScheme & fileScheme()
{
    return *getAllInputSchemes().at("file");
}

/* Claims file+https://nix-obtainium.invalid/<connector>/...?params before the
   builtin "file" scheme, but produces exactly the attrs "file" would. So the
   lock contains only type=file entries and a Nix without this plugin can still
   read the lock and fetch the locked URL. Only resolving (update) needs us. */
struct ObtainiumInputScheme : InputScheme
{
    // Must sort before "file": Input::fromURL tries schemes in map order.
    std::string_view schemeName() const override
    {
        return "a-obtainium";
    }

    std::string schemeDescription() const override
    {
        return "Resolve the latest release asset through a connector, lock it as a plain file input.";
    }

    std::optional<Input> inputFromURL(const Settings & settings, const ParsedURL & url, bool requireTree) const override
    {
        if (!url.authority || url.authority->host != obtainiumHost)
            return std::nullopt;
        if (parseUrlScheme(url.scheme).application != "file")
            throw Error("'%s': obtainium inputs must use the 'file+https://%s/...' form", url.to_string(), obtainiumHost);
        return fileScheme().inputFromURL(settings, url, requireTree);
    }

    std::optional<Input> inputFromAttrs(const Settings &, const Attrs &) const override
    {
        return std::nullopt;
    }

    const std::map<std::string, AttributeInfo> & allowedAttrs() const override
    {
        return fileScheme().allowedAttrs();
    }

    ParsedURL toURL(const Input & input) const override
    {
        return fileScheme().toURL(input);
    }

    std::pair<ref<SourceAccessor>, Input>
    getAccessor(const Settings & settings, Store & store, const Input & input) const override
    {
        auto url = parseURL(getStrAttr(input.attrs, "url"));
        auto shown = url.to_string();
        auto segments = url.pathSegments(true);
        auto it = segments.begin();
        if (it == segments.end())
            throw Error("'%s': missing connector name in URL path", shown);

        // Only connectors baked in at build time: they are pinned like everything else in Nix.
        auto program = std::filesystem::path(NIX_OBTAINIUM_CONNECTORS) / ("nix-obtainium-" + *it);
        if (access(program.c_str(), X_OK) != 0)
            throw Error("'%s': connector '%s' is not installed (looked for %s)", shown, *it, program.string());

        nlohmann::json request{
            {"path", std::vector<std::string>(std::next(it), segments.end())},
            {"query", url.query},
            {"accessTokens", settings.accessTokens.get()},
        };

        auto [status, out] = runProgram(RunOptions{
            .program = program,
            .lookupPath = false,
            .input = request.dump(),
        });
        if (status != 0)
            throw Error("'%s': connector '%s' %s", shown, *it, statusToString(status));

        std::string realUrl, version;
        try {
            auto response = nlohmann::json::parse(out);
            realUrl = response.at("url").get<std::string>();
            version = response.at("version").get<std::string>();
        } catch (nlohmann::json::exception & e) {
            throw Error("'%s': connector '%s' returned invalid output: %s", shown, *it, e.what());
        }
        debug("%s: resolved %s", shown, version);

        /* The version rides in the URL fragment: curl never sends it, and the
           lock has no other attr fetchTree would accept (it rejects "name" too). */
        auto lockedUrl = parseURL(realUrl);
        lockedUrl.fragment = version;
        auto locked = Input::fromAttrs(settings, {{"type", "file"}, {"url", lockedUrl.to_string()}});
        auto file = downloadFile(store, settings, realUrl, locked.getName());
        locked.attrs.insert_or_assign(
            "narHash", store.queryPathInfo(file.storePath)->narHash.to_string(HashFormat::SRI, true));
        return {ref{store.getFSAccessor(file.storePath)}, locked};
    }
};

static auto rObtainiumInputScheme = OnStartup([] { registerInputScheme(std::make_unique<ObtainiumInputScheme>()); });

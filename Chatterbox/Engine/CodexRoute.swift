import Foundation

/// How a Codex chat reaches OpenAI, chosen per chat:
/// - Direct: your ChatGPT sign-in (`model_provider = openai`), with ChatGPT's hosted tools
///   (image generation, apps such as Gmail). Never an API key: without a ChatGPT sign-in it
///   isn't offered, so nothing falls back to paid API billing.
/// - EasyCLIProxy: the local proxy that pools your sign-ins. Fine for coding; hosted tools
///   may be missing.
/// Unset follows the default: the proxy if it's on in Settings, otherwise whatever
/// ~/.codex/config.toml names (which EasyCLIProxy's own setup may point at itself).
enum CodexRoute: String, CaseIterable, Identifiable {
    case direct, proxy
    var id: String { rawValue }
    var title: String { self == .direct ? "Direct (ChatGPT)" : "EasyCLIProxy" }
}

extension ChatSession {
    var codexRoute: CodexRoute? { record.codex?.route.flatMap(CodexRoute.init) }

    func setCodexRoute(_ route: CodexRoute?) {
        guard record.codex != nil, record.codex?.route != route?.rawValue else { return }
        record.codex?.route = route?.rawValue
        noteSettingsChange()
        onChange?(self)
    }

    /// The thread config for this chat's connection, a key that changes when it does (which
    /// reopens the thread with the new connection), and what it is in words.
    var codexConnection: (config: [String: JSON], key: String, isDirect: Bool, summary: String) {
        if let model = record.openModel {
            return (openModelCodexConfig, "open:\(record.runOn ?? "mac"):\(model)", false,
                    "Open-weight model \(model) on \(RemoteMachine.pc.name). Hosted tools such as image generation aren't available.")
        }
        // On the PC: EasyCLIProxy here through the Codex server's tunnel, as on the Mac (on
        // in Settings, or picked), else the PC's own ChatGPT sign-in.
        if let machine = runMachine {
            let proxy = codexRoute == .direct ? nil : codexRoute == .proxy ? EasyCLIProxy.shared.available() : EasyCLIProxy.shared.active(for: .codex)
            if let proxy {
                let pc = proxy.onPC(port: EasyCLIProxy.pcCodexPort)
                return (EasyCLIProxy.shared.codexConfig(pc), "pc:proxy:" + pc.base, false,
                        "Through EasyCLIProxy on this Mac. Hosted tools such as image generation may be missing.")
            }
            return (["model_provider": "openai"], "pc:direct", true, "Direct through \(machine.name)'s ChatGPT sign-in."
                    + (codexRoute == .proxy ? " EasyCLIProxy isn't available." : ""))
        }
        let globalProvider = EasyCLIProxy.directCodexProvider
        let signedIn = EasyCLIProxy.codexHasChatGPTSignIn
        let appProxy = EasyCLIProxy.shared.active(for: .codex)
        switch codexRoute {
        case .direct where signedIn:
            return (["model_provider": "openai"], "route:direct", true, "Direct through your ChatGPT sign-in, with hosted tools like image generation.")
        case .proxy:
            if let appProxy { return (EasyCLIProxy.shared.codexConfig(appProxy), "route:proxy:" + appProxy.base, false, "Through EasyCLIProxy. Hosted tools such as image generation may be missing.") }
            if globalProvider != "openai" {
                return (["model_provider": .string(globalProvider)], "route:proxy:" + globalProvider, false, "Through \(globalProvider) (your Codex default). Hosted tools such as image generation may be missing.")
            }
            fallthrough
        default:
            let suffix = codexRoute == .direct ? " Direct needs a ChatGPT sign-in (run codex login)." : codexRoute == .proxy ? " EasyCLIProxy isn't available." : ""
            if let appProxy {
                return (EasyCLIProxy.shared.codexConfig(appProxy), "proxy:" + appProxy.base, false, "Default: through EasyCLIProxy (on in Settings)." + suffix)
            }
            let direct = globalProvider == "openai"
            return (["model_provider": .string(globalProvider)], "direct", direct,
                    (direct ? "Default: direct through OpenAI." : "Default: through \(globalProvider), your Codex default. Hosted tools such as image generation may be missing.") + suffix)
        }
    }

    /// A note for the agent when its connection changed since it was last told, so it knows
    /// whether hosted tools came back or may be gone. Only for a connection you chose.
    func takeCodexRouteUpdate() -> String? {
        guard record.codex != nil else { return nil }
        let connection = codexConnection
        let told = record.codex?.sentRoute
        guard told != connection.key else { return nil }
        record.codex?.sentRoute = connection.key
        guard told != nil || codexRoute != nil else { return nil }
        return connection.isDirect
            ? "<app_note>\nThis session now connects to Codex directly through the user's ChatGPT sign-in. ChatGPT's hosted tools, such as image generation, are available again: use them instead of asking for an API key.\n</app_note>"
            : "<app_note>\nThis session now connects through EasyCLIProxy, not directly. ChatGPT's hosted tools (such as image generation) may be unavailable. If a task needs one, say so and suggest switching this session's Connection to Direct; don't ask for an API key.\n</app_note>"
    }
}

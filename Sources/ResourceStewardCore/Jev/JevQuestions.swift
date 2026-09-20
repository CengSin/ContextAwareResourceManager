import Foundation


public enum JevQuestions: Sendable {
    public static let defaultModel = "jev-latest"

    public static func payload() -> [String: Any] {
        [
            "looks_like_network_or_sync": [
                "type": "noul",
                "instructions": "Does this app primarily perform network sync, cloud backup, file transfer, torrenting, or always-on tunnel/proxy work?",
                "criteria": [
                    "true": "Evidence of sync clients, cloud drives, downloaders, proxies, VPN helpers, or background network agents.",
                    "false": "Ordinary local UI app with incidental network use, or insufficient evidence."
                ]
            ],
            "looks_like_communication": [
                "type": "noul",
                "instructions": "Does this look like chat, email, messaging, social inbox, or collaboration communication the user may miss if paused?",
                "criteria": [
                    "true": "IM, mail, Slack-like collaboration, social messaging clients.",
                    "false": "Not primarily a communication client."
                ]
            ],
            "looks_like_input_or_a11y": [
                "type": "noul",
                "instructions": "Does this look like an input method, accessibility aid, clipboard/launcher utility, or assistive tool that should stay running?",
                "criteria": [
                    "true": "IME, screen reader, magnifier, launcher, clipboard manager, or similar a11y/input helper.",
                    "false": "Ordinary application UI, not an input/a11y utility."
                ]
            ],
            "looks_like_av_or_capture": [
                "type": "noul",
                "instructions": "Does this look like audio/video meeting, screen recording, camera capture, or livestream tooling?",
                "criteria": [
                    "true": "Meeting, recording, capture, streaming, or camera/mic focused apps.",
                    "false": "Not AV/capture focused."
                ]
            ],
            "user_likely_needs_soon": [
                "type": "noul",
                "instructions": "Given idle time, memory pressure, and app identity, is the user likely to need this app again soon (minutes)?",
                "criteria": [
                    "true": "Recently used, sticky workflow app, or low idle with likely return.",
                    "false": "Clearly idle long enough that reclaim is unlikely to interrupt the user soon."
                ]
            ],
            "safe_to_reclaim_idle": [
                "type": "noul",
                "instructions": "From the app's identity and idle/memory state, is it reasonable to reclaim CPU/memory from this idle third-party app (throttle, freeze, or quit)? Do not judge window-server safety; local code handles that.",
                "criteria": [
                    "true": "Idle third-party app; reclaiming is unlikely to lose critical state or break connectivity/AV/input.",
                    "false": "Unsafe, uncertain, or user may need it; prefer leaving alone."
                ]
            ],
            "preferred_action": [
                "type": "choice",
                "instructions": "Pick the single best reclaim action from the app's identity, idle/memory state, and system load. Prefer the mildest effective action; choose none when uncertain. Freeze is disabled — never pick freeze.",
                "criteria": [
                    "none": "Do nothing: risk, uncertainty, or user likely needs the app.",
                    "throttle": "Lower CPU priority only; keep the process running.",
                    "quit": "Ask the app to quit when restart is cheap and throttle is insufficient."
                ]
            ]
        ]
    }
}

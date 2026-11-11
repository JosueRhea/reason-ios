# Reason for iOS

An unofficial native iOS client for [Reason Machines](https://reasonmachines.com), written in UIKit.

Chat with your Reasons and Sessions, watch replies stream in, answer request cards (secrets, questions, network access), share into a Reason from other apps, and get push notifications when a turn finishes.

## Build

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open Reason.xcodeproj
```

Set your own `DEVELOPMENT_TEAM` and bundle identifiers in `project.yml`, then run. Sign in with a Reason API key.

`relay/` is an optional Cloudflare Worker that turns Reason webhooks into APNs pushes (`wrangler deploy`, then `wrangler secret put APNS_KEY`).

## Credits

- Built on the public [Reason Machines API](https://reasonmachines.com). This project is not affiliated with or endorsed by Reason Machines. "Reason" and "Reason Machines" belong to their owners.
- Provider logos (OpenAI, Anthropic, Claude, Gemini, OpenRouter and others) are trademarks of their respective owners and are used only to identify models. Their paths come from [T3 Code](https://github.com/pingdotgg/t3code)'s provider icons.
- GitHub mark from [Octicons](https://github.com/primer/octicons) (MIT).

## License

[MIT](LICENSE)

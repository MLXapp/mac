# MLX Node

MLX Node is the menu bar app that lets your Mac do AI work for [MLX Network](https://mlx.app) in its spare time, and earn MLX Tokens for verified work.

[Download](https://mlx.app/download) · [How it works](https://mlx.app/learn/is-mlx-safe) · [Live map](https://world.mlx.app) · [Whitepaper](https://mlx.app/whitepaper)

This is the source of the app that ships on mlx.app as `MLX-Node-<version>.dmg` (for example `MLX-Node-090.dmg`), signed with Developer ID and notarized by Apple. It's published so you can read exactly what runs on your Mac, build it yourself, and help make it better.

## What it does

- **Runs only when you let it.** Start and Stop by hand, or after the Mac has been idle for the time you choose. Limits cover power, heat, Low Power Mode and hours of the day (`Core/Policy.swift`). When you touch the Mac, the job stops within a token and the GPU is free again.
- **Runs AI jobs with Apple's MLX.** Jobs are language-model prompts, run with greedy decoding through [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) on models from Hugging Face's `mlx-community` (`Core/Worker.swift`). Each result goes back to the network as a hash of the generated token ids, so different Macs can be compared.
- **Earns for verified work.** The network scores each linked Mac every hour on time available, jobs done and agreement with other Macs. Rewards are recorded on the public ledger ([explorer](https://explorer.mlx.app)).
- **Can't see your files.** The app runs in the App Sandbox with network access only, plus Downloads for updates.

MLX Studio, the Mac app for running models locally, carries MLX Node inside and installs it on first run.

## How it works

- **Identity:** a P-256 key created in the Secure Enclave (`Core/DeviceKey.swift`). The private key can't leave the Mac. Every request carries the header `x-mlx-device: <key>|<ms>|<sig>`, signed over the canonical JSON of method, path, body hash and time (`Core/Canonical.swift`).
- **Linking a wallet:** the app opens a link request in the MLX wallet. You approve it with your passkey, and the wallet records it on the ledger (`bind_device`). The app then polls `/api/device/<key>` until the link shows up.
- **Wallet:** the panel embeds the MLX web wallet (`UI/WalletView.swift`), which talks to the app through a small message bridge.
- **Updates:** when a newer notarized build is available, the panel shows an Update button. The installer service (`MLXUpdater/`, an XPC service only MLX Node can reach) mounts the disk image read-only and checks that the app inside is signed by MLX's Developer ID (team `CCKXS9W488`, bundle `app.mlx.mac`) and is newer. Then it swaps the app in with one atomic rename. Nothing installs without your click.

## Build

You need an Apple Silicon Mac with Xcode 26 or later.

```sh
brew install xcodegen
xcodegen generate
open MLX.xcodeproj
# or
xcodebuild -project MLX.xcodeproj -scheme MLX -configuration Release -skipMacroValidation build
```

Local builds are ad-hoc signed. The first time, open the app with right-click → Open. Self-built apps can't update themselves: the updater only accepts builds signed by MLX's Developer ID.

To run against a local server:

```sh
defaults write app.mlx.mac apiBase http://localhost:3031
```

To check the engine on your Mac (signed request to mlx.app, model download, one job on the GPU):

```sh
"build/Build/Products/Release/MLX Node.app/Contents/MacOS/MLX" --selftest
```

## Contributing

Issues and pull requests are welcome. Please keep changes small and focused, and run the unit tests (`xcodebuild test -scheme MLX`) before opening a pull request. Security issues: see [SECURITY.md](SECURITY.md).

Official builds come from MLX Network's release pipeline, which signs, notarizes and publishes them on [mlx.app/download](https://mlx.app/download). This repository mirrors that source.

## License

Apache License 2.0. See [LICENSE](LICENSE). The MLX and MLX Node names, logo and app icon are trademarks of MLX Network and are not licensed for use in other apps.

MLX Network is independent and not affiliated with Apple. "MLX" here is the network; [Apple's MLX](https://github.com/ml-explore/mlx) is the machine learning framework the app uses.

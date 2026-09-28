# Third Hand

> Third Hand was a proof of concept to show that we can use Jev for computer use, but now we are building a full-fledged assistant.

A small macOS menu bar assistant. Focus an app, press **Control–Space**, and tell it what to do.

Third Hand reads accessible controls, types, clicks, and checks the result. Press **Control–Space** again or click **×** to stop.

## Download

[Download the latest release](https://github.com/shhivv/third-hand/releases/latest) for Apple Silicon Macs running macOS 14 or newer. Unzip the archive, move **Third Hand.app** to Applications, and open it. Release builds are Developer ID-signed and notarized by Apple. A ChatGPT account with Codex access and a TypeSafe API key are required.

## Build from source

You’ll need **Xcode 15 or newer**, an Apple Development or Developer ID signing certificate, and a [TypeSafe API key](https://typesafe.ai).

```sh
git clone git@github.com:shhivv/third-hand.git
cd third-hand
./rebuild.sh
open "Third Hand.app"
```

In the setup window:

1. Enable **Accessibility** so Third Hand can read and control apps.
2. Enable **Screen Recording** for local text recognition when an app’s controls aren’t accessible.
3. Add your **TypeSafe API key**. It’s saved in macOS Keychain.
4. Click **Sign in with ChatGPT** and finish signing in in your browser. Tokens are saved in macOS Keychain.

Switch to an app, press **Control–Space**, and try a specific task, such as “Search for Adele.”

The app runs on macOS 14+. Apple Intelligence is not required.

## How it works

- **Accessibility** reads controls and their current values.
- **Apple Vision** reads screen text locally when needed. Screenshots aren’t uploaded.
- **ChatGPT (Codex)** plans the task one step at a time and writes any text to enter: search terms, messages, commands. Your request, app name, screen labels and values, and step results are sent to OpenAI through your ChatGPT account. The model defaults to `gpt-6-sol`; override it with `defaults write com.thirdhand.app CodexModel <model>`.
- **Jev** grounds each step to a control on screen and Third Hand executes and verifies it. The step, app name, screen labels and values, and recent action history are sent to TypeSafe.
- Third Hand is **not offline**.

No bundled model weights or extra runtime dependencies. Third Hand never restarts the apps it controls.

## Development

```sh
./rebuild.sh       # Build, sign, and update Third Hand.app
swift test         # Run tests without calling the live API
```

Always run the repository-root `Third Hand.app`. The build script keeps the same signing identity to preserve macOS permissions and retains the previous app in `.build/install.*`. Keep `.thirdhand-signing-identity` on your machine; it is excluded from Git. If no certificate is available, create an Apple Development certificate in Xcode before building.

Setup shows current permission status. If macOS asks you to quit and reopen after granting access, reopen this same copy.

Diagnostic logs are written to `~/Desktop/thirdhand.log`. They include action status, timing, and bounded API rejection messages. Review logs before sharing: service error messages can contain request details. API keys are redacted from those messages.

In terminals, the planner can write and run shell commands. Third Hand types each command once and won't enter another until the pending one is submitted. Stay nearby: commands run with your user's permissions.

## Status

An early, experimental project. Some apps expose incomplete controls; icon-only interfaces, custom editors, and complex gestures may not work. A task can stop without completing, and reported completion still needs your judgment. Stay nearby while it works.

Issues and pull requests are welcome. Please include your macOS version, the app involved, and the steps to reproduce. Don’t include API keys or private screen content.

## License

[MIT](LICENSE) — Shiv Shanmugam · [shiv@tryisle.com](mailto:shiv@tryisle.com)

# Third Hand

> Third Hand was a proof of concept to show that we can use Jev for computer use, but now we are building a full-fledged assistant.

A macOS assistant you chat with. Tag an app with **@** in a thread, like `@Spotify play something chill`, and Third Hand does it: it reads the app's accessible controls, clicks and types, and checks the result.

- **Threads** work like channels: each keeps its own history, so follow-ups ("now play the second one") work. A message without an @ uses the thread's last app.
- **@mentions** list running and installed apps; tagging one that isn't open launches it.
- **Control–Space** in any app opens a new thread with that app already tagged.
- Click **Stop** on a running task to cancel it. Tasks run one at a time and take over the screen while they work.

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

Open Third Hand from the Dock, start a thread, and try a specific task, such as “@Spotify search for Adele.”

The app runs on macOS 14+. Apple Intelligence is not required.

## How it works

- **Accessibility** reads controls and their current values.
- **Apple Vision** reads screen text locally when needed. Screenshots aren’t uploaded.
- **ChatGPT (Codex)** plans the whole task in one go as a list of simple steps (click, type, press, scroll, wait), naming each control by its on-screen label, and writes any text to enter: search terms, messages, commands. It's asked again only if a step fails. Your request, app name, screen labels and values, and step results are sent to OpenAI through your ChatGPT account. Planning uses `gpt-6-sol` with no reasoning effort, and retries with low effort after a failed step; pin either with `defaults write com.thirdhand.app CodexModel <model>` or `CodexEffort <effort>`.
- **Jev** picks the control when a step's label is ambiguous or doesn't match exactly, choosing only among controls that fit the step. Third Hand then executes and verifies each step. The step, app name, and candidate labels and values are sent to TypeSafe.
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

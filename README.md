# ritmos personal script

> [!WARNING]
> **Use at your own risk and discretion.** This is a personal script, shared as-is, with no warranty and no support. It changes macOS settings and uses private Apple frameworks that can stop working or misbehave after any macOS update. Read the code before you run it: you are responsible for what it does on your Mac.

`ritmos` builds **QuickToggles**, a tiny menu bar app. Click the coffee cup for a Liquid Glass panel with three switches:

- **Keep Display Awake** runs `caffeinate -d` for up to 45 minutes, then switches itself off so the battery doesn't drain.
- **Standard Function Keys** flips the "Use F1, F2, etc. keys as standard function keys" setting and applies it immediately.
- **Night Mode** turns Night Shift, True Tone and auto-brightness on or off together.

**Preferences** at the bottom of the panel lets you hide the short description under each switch, set how see-through the glass is, and tune how bouncy and how fast the panel animates.

## Install

On any Mac with [Homebrew](https://brew.sh), paste this into Terminal:

```bash
brew tap printmoney/tap && brew trust printmoney/tap && brew install printmoney/tap/ritmos && ritmos
```

That adds the tap, trusts it (Homebrew asks for this once for third-party taps), installs the `ritmos` command and runs it. `ritmos` compiles QuickToggles on your Mac, installs it to `~/Applications/QuickToggles.app` and opens it.

It needs the Xcode Command Line Tools, which Homebrew installs. Without Homebrew, run `xcode-select --install`, clone this repo and run `./ritmos.sh`.

## Update

```bash
brew update && brew upgrade ritmos && ritmos
```

## Uninstall

Quit QuickToggles from its menu, then:

```bash
brew uninstall ritmos && rm -rf ~/Applications/QuickToggles.app
```

## Publishing a new version

1. Change `ritmos.sh` (or replace it with a new version of the script) and commit.
2. Run `./release.sh 1.1.0`, using the new version number.

`release.sh` tags the commit, pushes it and points the Homebrew formula in [printMoney/homebrew-tap](https://github.com/printMoney/homebrew-tap) at the new version. It needs the GitHub CLI (`gh`), logged in.

## Disclaimer

This is a personal project, published so it's backed up and easy to install. It is not affiliated with or endorsed by Apple. The app isn't signed with a Developer ID or notarized; it's compiled and ad-hoc signed on your own Mac. Night Mode relies on undocumented Apple frameworks (CoreBrightness and DisplayServices), and the function-key toggle writes a system-wide keyboard preference. Any of this may break with a macOS update.

The software is provided "as is", without warranty of any kind, and the authors aren't liable for any damage or data loss that comes from using it. See [LICENSE](LICENSE) (MIT).

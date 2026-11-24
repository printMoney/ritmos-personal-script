#!/bin/bash
# Publishes a new version of ritmos so `brew upgrade ritmos` picks it up.
#
#   ./release.sh 1.1.0
#
# Tags the current commit as v1.1.0, pushes it to GitHub, then writes
# Formula/ritmos.rb in printMoney/homebrew-tap so it points at that tag.
# Needs the GitHub CLI (`gh`), logged in to an account that can push to both repos.
# The formula is generated from the template below: change it here, not in the tap.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?Usage: ./release.sh <version>, for example ./release.sh 1.1.0}"
VERSION="${VERSION#v}"
TAG="v$VERSION"
REPO="printMoney/ritmos-personal-script"
TAP="printMoney/homebrew-tap"
FORMULA_PATH="Formula/ritmos.rb"

if [ -n "$(git status --porcelain)" ]; then
  echo "You have uncommitted changes. Commit them first, then run this again." >&2
  exit 1
fi

# 1. Tag the current commit and push it (git authenticates through gh).
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "ritmos $VERSION"
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
  push origin HEAD "refs/tags/$TAG"

# 2. Checksum the source archive GitHub serves for that tag.
SHA256="$(curl -fsSL --retry 3 "https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz" \
  | shasum -a 256 | cut -d ' ' -f 1)"

# 3. Write the formula to the tap.
FORMULA="$(sed -e "s/@VERSION@/$VERSION/g" -e "s/@SHA256@/$SHA256/g" <<'RUBY'
class Ritmos < Formula
  desc "Builds QuickToggles, a menu bar app with handy Mac toggles"
  homepage "https://github.com/printMoney/ritmos-personal-script"
  url "https://github.com/printMoney/ritmos-personal-script/archive/refs/tags/v@VERSION@.tar.gz"
  sha256 "@SHA256@"
  license "MIT"
  head "https://github.com/printMoney/ritmos-personal-script.git", branch: "main"

  depends_on :macos

  def install
    bin.install "ritmos.sh" => "ritmos"
  end

  def caveats
    <<~EOS
      Run `ritmos` to build QuickToggles.app into ~/Applications and open it.
      After `brew upgrade ritmos`, run `ritmos` again to rebuild the app.

      This is a personal script, provided as-is: use at your own risk.
    EOS
  end

  test do
    system "bash", "-n", bin/"ritmos"
  end
end
RUBY
)"

FILE_SHA="$(gh api "repos/$TAP/contents/$FORMULA_PATH" --jq .sha 2>/dev/null)" || FILE_SHA=""
ARGS=(
  --method PUT "repos/$TAP/contents/$FORMULA_PATH"
  -f message="ritmos $VERSION"
  -f content="$(printf '%s\n' "$FORMULA" | base64 | tr -d '\n')"
  -f "author[name]=$(git config user.name)"
  -f "author[email]=$(git config user.email)"
)
if [ -n "$FILE_SHA" ]; then
  ARGS+=(-f sha="$FILE_SHA")
fi
gh api "${ARGS[@]}" --silent

echo "Released ritmos $VERSION."
echo "On your Macs: brew update && brew upgrade ritmos && ritmos"

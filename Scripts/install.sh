#!/bin/bash
# Installs Tinybar with Homebrew and walks through macOS's first-launch approval, which an app
# that isn't notarized yet needs once:
#   curl -fsSL https://raw.githubusercontent.com/ThiloReintjes/tinybar/main/Scripts/install.sh | bash
set -euo pipefail

bold=$'\e[1m' blue=$'\e[1;34m' green=$'\e[1;32m' yellow=$'\e[1;33m' reset=$'\e[0m'
step() { printf '\n%s==>%s %s%s%s\n' "$blue" "$reset" "$bold" "$1" "$reset"; }
wait_enter() { printf '    %s' "$1"; read -r < /dev/tty; }

command -v brew > /dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }

step "Installing Tinybar"
brew install --cask thiloreintjes/tinybar/tinybar

running() { sleep 2; pgrep -x Tinybar > /dev/null; }
done_msg() { printf '\n%sTinybar is running.%s Look for the ring in your menu bar.\n' "$green" "$reset"; }

# Read the steps before the warning appears: macOS shows it the moment Tinybar is opened.
step "macOS blocks Tinybar once, because it isn't notarized yet"
cat <<MSG

    ${yellow}1.${reset} On the "Tinybar Not Opened" warning, click ${bold}Done${reset} (not Move to Trash).
    ${yellow}2.${reset} In Settings, scroll down and click ${bold}Open Anyway${reset}, then confirm.

MSG
wait_enter "Press Enter to open Tinybar… "
open -a Tinybar
if running; then done_msg; exit 0; fi

wait_enter "Clicked Done? Press Enter to open Settings… "
open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
wait_enter "Clicked Open Anyway? Press Enter to start Tinybar… "
open -a Tinybar
if running; then
    done_msg
else
    printf '\nTinybar did not start yet. Click Open Anyway in Settings, then run: open -a Tinybar\n'
fi

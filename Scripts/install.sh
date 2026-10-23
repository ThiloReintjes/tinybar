#!/bin/bash
# Installs Tinybar with Homebrew and opens it:
#   curl -fsSL https://raw.githubusercontent.com/ThiloReintjes/tinybar/main/Scripts/install.sh | bash
set -euo pipefail

command -v brew > /dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }

brew install --cask thiloreintjes/tinybar/tinybar
open -a Tinybar
printf '\n\e[1;32mTinybar is running.\e[0m Look for the ring in your menu bar.\n'

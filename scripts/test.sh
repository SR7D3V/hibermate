#!/bin/sh
# Runs the HibermateCore unit tests.
#
# Build products go to ~/Library/Caches instead of the repo. If the repo lives
# in an iCloud-synced folder (e.g. ~/Documents), file-provider extended
# attributes on build output make codesign fail, and iCloud would upload every
# build artifact.
set -eu
cd "$(dirname "$0")/../Packages/HibermateCore"
exec swift test --scratch-path "${HIBERMATE_BUILD_DIR:-$HOME/Library/Caches/hibermate-build}/spm" "$@"

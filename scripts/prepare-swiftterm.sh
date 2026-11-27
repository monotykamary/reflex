#!/bin/sh
# Apply Reflex's narrowly scoped patches to SwiftTerm 1.20.0 after resolution,
# including on clean builds. Fail closed if a changed dependency no longer
# matches any patch.
set -eu
cd "$(dirname "$0")/.."
root=$PWD
swift package --package-path app resolve
checkout="$root/app/.build/checkouts/SwiftTerm"

for name in swiftterm-link-padding.patch swiftterm-inline-emulation.patch; do
  patch="$root/scripts/patches/$name"
  if git -C "$checkout" apply --reverse --check "$patch" 2>/dev/null; then
    echo "SwiftTerm: $name already applied"
  elif git -C "$checkout" apply --check "$patch"; then
    git -C "$checkout" apply "$patch"
    echo "SwiftTerm: applied $name"
  else
    echo "SwiftTerm: $name does not match the resolved dependency" >&2
    exit 1
  fi
done

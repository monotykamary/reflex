#!/bin/sh
# SwiftTerm 1.20.0 includes end-of-row padding in implicit path links.
# Apply our narrowly scoped source/test patch after resolution, including on
# clean builds. Fail closed if a changed dependency no longer matches it.
set -eu
cd "$(dirname "$0")/.."
root=$PWD
swift package --package-path app resolve
checkout="$root/app/.build/checkouts/SwiftTerm"
patch="$root/scripts/patches/swiftterm-link-padding.patch"

if git -C "$checkout" apply --reverse --check "$patch" 2>/dev/null; then
  echo "SwiftTerm: link-padding patch already applied"
elif git -C "$checkout" apply --check "$patch"; then
  git -C "$checkout" apply "$patch"
  echo "SwiftTerm: applied link-padding patch"
else
  echo "SwiftTerm: link-padding patch does not match the resolved dependency" >&2
  exit 1
fi

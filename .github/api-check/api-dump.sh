#!/bin/zsh
# Keeps the evidence that api-check.swift deletes, so one saved baseline can be
# compared many times without a second build of the base.
#
#   api-dump.sh <out-dir> [platform]       build the current checkout, save its API surface
#   api-dump.sh --diff <base-dir> <head-dir>   compare two saved surfaces
#
# Build flags match api-check.swift. JOBS (default 2) and CACHE (default
# <out-dir>/.cache) are the only knobs.
set -euo pipefail

if [[ "${1:-}" == "--diff" ]]; then
    base=$2 head=$3
    # The digester reports only breakage. The reversed run shows additions as removals.
    xcrun swift-api-digester -diagnose-sdk -input-paths "$base/api.json" -input-paths "$head/api.json" -o "$head/breaking.txt"
    xcrun swift-api-digester -diagnose-sdk -input-paths "$head/api.json" -input-paths "$base/api.json" -o "$head/additions-reversed.txt"
    # The digester does not see @objc enum raw values, selectors or protocol
    # optionality. The generated header states all three.
    diff -u "$base/LiveKit-Swift.h" "$head/LiveKit-Swift.h" > "$head/objc-header.diff" || true
    grep -v '^$' "$head/breaking.txt" || true
    echo "objc-header.diff: $(grep -c '^[-+][^-+]' "$head/objc-header.diff" || true) changed lines"
    exit 0
fi

platform=${2:-macOS}
out=$1/$platform
cache=${CACHE:-$1/.cache}
dd=$cache/dd-$platform
repo=$(git rev-parse --show-toplevel)
mkdir -p "$out"

xcodebuild build -quiet -scheme LiveKit -configuration Release \
    -destination "generic/platform=$platform" \
    -derivedDataPath "$dd" -clonedSourcePackagesDirPath "$cache/spm" \
    -jobs "${JOBS:-2}" ARCHS=arm64 BUILD_LIBRARY_FOR_DISTRIBUTION=YES

products=("$dd"/Build/Products/Release*(N[1]))
swiftmodules=("$products"/LiveKit.swiftmodule/*.swiftmodule(N))
triple=${swiftmodules[1]:t:r}
suffix=${${products:t}#Release}
sdk=$(xcrun --sdk "${${suffix#-}:-macosx}" --show-sdk-path)
modulemap=$(find "$dd/Build/Intermediates.noindex" -name CLiveKitProto.modulemap | head -1)

xcrun swift-api-digester -dump-sdk -module LiveKit -target "$triple" -sdk "$sdk" \
    -I "$products" -F "$products" -F "$products/PackageFrameworks" \
    -abort-on-module-fail -o "$out/api-raw.json" \
    -Xcc "-fmodule-map-file=$modulemap" -Xcc "-I$repo/Sources/CLiveKitProto/include"
[[ -s "$out/api-raw.json" ]] || { echo "swift-api-digester produced no dump" >&2; exit 1; }
# Same prune as api-check.swift: `package` declarations are not public API.
jq 'walk(if type == "object" and has("children") then .children |= map(select(.isInternal != true)) else . end)' \
    "$out/api-raw.json" > "$out/api.json"

cp "$products"/LiveKit.swiftmodule/*.swiftinterface "$out/"
cp "$(find "$dd/Build/Intermediates.noindex" -name LiveKit-Swift.h | head -1)" "$out/"
resolved=$repo/Package.resolved
[[ -f $resolved ]] && cp "$resolved" "$out/"
{
    echo "commit: $(git -C "$repo" rev-parse HEAD) ($(git -C "$repo" describe --tags --always))"
    echo "trees: Sources=$(git -C "$repo" rev-parse HEAD:Sources) Package.swift=$(git -C "$repo" rev-parse HEAD:Package.swift)"
    echo "uncommitted (must not touch Sources or Package.swift):"
    git -C "$repo" status --porcelain
    echo "platform: $platform  triple: $triple  sdk: $sdk"
    echo "flags: Release ARCHS=arm64 BUILD_LIBRARY_FOR_DISTRIBUTION=YES"
    xcodebuild -version
    xcrun swift --version 2>&1
    shasum -a 256 "$out"/api-raw.json "$out"/api.json "$out"/*.swiftinterface "$out"/LiveKit-Swift.h
} > "$out/provenance.txt"
cat "$out/provenance.txt"

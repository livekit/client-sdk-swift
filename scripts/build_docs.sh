#!/bin/zsh
# Builds multi-platform documentation using xcodebuild and DocC.
# When running locally, pass the `--preview` flag to serve docs.

TARGET="LiveKit"
DOCC_SOURCE_PATH="${PWD}/Sources/${TARGET}/${TARGET}.docc"
SUPPORTED_PLATFORMS=("macOS" "iOS Simulator" "tvOS Simulator" "visionOS Simulator")
HOSTING_BASE_PATH="client-sdk-swift/"

BUILD_DIR="${PWD}/.docs"
DERIVED_DATA_DIR="${BUILD_DIR}/derived-data"
SYMBOLS_DIR="${BUILD_DIR}/symbol-graph"

# Location of the generated docs for static hosting
OUTPUT_DIR="${BUILD_DIR}/output"

build_for_platform() {
    local platform=$1
    local platform_symbols_dir="${SYMBOLS_DIR}/${platform}"

    mkdir -p "${platform_symbols_dir}"

    xcodebuild build \
        -scheme "${TARGET}" \
        -destination "platform=${platform}" \
        -derivedDataPath "${DERIVED_DATA_DIR}" \
        OTHER_SWIFT_FLAGS="-Xfrontend -emit-symbol-graph\
                           -Xfrontend -emit-symbol-graph-dir\
                           -Xfrontend ${platform_symbols_dir}" \
        DOCC_EXTRACT_EXTENSION_SYMBOLS=YES

    # Ensure symbols were emitted
    if [ -z "$(ls -A "${platform_symbols_dir}")" ]; then
        echo "::error::No symbol graphs were generated for ${platform}."
        exit 1
    fi
}

for platform in "${SUPPORTED_PLATFORMS[@]}"; do
    echo "::group::Building for ${platform}"
        build_for_platform "${platform}"
    echo "::endgroup::"
done

# If `--preview` flag is passed, serve docs locally
if [[ "$@" == *"--preview"* ]]; then
    $(xcrun --find docc) preview \
        "${DOCC_SOURCE_PATH}" \
        --additional-symbol-graph-dir "${SYMBOLS_DIR}"
    exit 0
fi

echo "::group::Building docs for static hosting"
$(xcrun --find docc) convert \
    "${DOCC_SOURCE_PATH}" \
    --output-dir "${OUTPUT_DIR}" \
    --transform-for-static-hosting \
    --hosting-base-path "${HOSTING_BASE_PATH}" \
    --additional-symbol-graph-dir "${SYMBOLS_DIR}"
echo "::endgroup::"

echo "::group::Verifying output"
if [ ! -f "${OUTPUT_DIR}/index.html" ]; then
    echo "::error::index.html not found in output directory"
    exit 1
else
    echo "::notice::Documentation successfully generated at ${OUTPUT_DIR}"
fi
echo "::endgroup::"

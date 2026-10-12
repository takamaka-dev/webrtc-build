#!/bin/bash
# C182 / DR-055 (Takamaka) — iOS-only WebRTC.xcframework with tkm_sframe.patch applied.
# A trimmed copy of xcframework.sh: iOS only, 3 slices (arm64 device, arm64 simulator, x86_64 simulator), no
# macOS/catalyst/tvOS/visionOS. The x86_64 simulator slice is REQUIRED: the Takamaka build iMac is Intel.
# The GN args are upstream's COMMON_ARGS unchanged (same codecs, same symbol export, same deployment target), so the
# framework is the stock WebRTC-SDK pod's shape plus RTCSFrameKeyStore / RTCSFrameCryptor.
# Usage: tkm_xcframework.sh <debug|release> <webrtc_src_dir> <out_dir>
set -euo pipefail

MODE="$1"
SOURCE_DIR="$(realpath "$2")"
OUT_DIR="$(realpath "$3")"
FRAMEWORK_NAME="WebRTC"   # unprefixed: the module name the WebRTC-SDK pod and flutter_webrtc import
PARALLEL_BUILDS="${PARALLEL_BUILDS:-6}"

DEBUG="false"
if [[ "$MODE" == "debug" ]]; then
  DEBUG="true"
fi

start_group() { if [[ "${CI:-}" == "true" ]]; then echo "::group::$1"; else echo "=== $1 ==="; fi; }
end_group() { if [[ "${CI:-}" == "true" ]]; then echo "::endgroup::"; fi; }

COMMON_ARGS="
      enable_dsyms = $DEBUG
      enable_libaom = true
      enable_stripping = true
      ios_enable_code_signing = false
      is_component_build = false
      is_debug = $DEBUG
      rtc_build_examples = false
      rtc_enable_protobuf = false
      rtc_enable_symbol_export = true
      rtc_include_dav1d_in_internal_decoder_factory = true
      rtc_include_tests = false
      rtc_libvpx_build_vp9 = true
      rtc_use_h264 = false
      treat_warnings_as_errors = true
      use_rtti = true"

# x86_64 simulator FIRST: it is the slice the build iMac runs, and the first slice also compiles the SFrame
# Objective-C sources before anything else (fail fast on the part that is ours).
PLATFORMS=(
  "iOS-x64-simulator:target_os=\"ios\" target_environment=\"simulator\" target_cpu=\"x64\" ios_deployment_target=\"13.0\""
  "iOS-arm64-simulator:target_os=\"ios\" target_environment=\"simulator\" target_cpu=\"arm64\" ios_deployment_target=\"13.0\""
  "iOS-arm64-device:target_os=\"ios\" target_environment=\"device\" target_cpu=\"arm64\" ios_deployment_target=\"13.0\""
)

cd "$SOURCE_DIR"

first=1
for platform_config in "${PLATFORMS[@]}"; do
  platform="${platform_config%%:*}"
  config="${platform_config#*:}"
  start_group "Building $platform"
  gn gen "$OUT_DIR/$platform" --args="$COMMON_ARGS $config"
  if [[ $first == 1 ]]; then
    objs=$(ninja -C "$OUT_DIR/$platform" -t targets all | grep -o '^[^:]*RTCSFrame[^:]*\.o' | sort -u || true)
    if [[ -z "$objs" ]]; then
      echo "::error::no RTCSFrame object in the build graph: tkm_sframe.patch did not add the Objective-C API"
      exit 1
    fi
    echo "SFrame Objective-C objects: $objs"
    # shellcheck disable=SC2086
    ninja -C "$OUT_DIR/$platform" $objs
    first=0
  fi
  ninja -C "$OUT_DIR/$platform" ios_framework_bundle -j "$PARALLEL_BUILDS" --quiet
  end_group
done

start_group "Creating the simulator fat binary (arm64 + x86_64)"
mkdir -p "$OUT_DIR/iOS-device-lib" "$OUT_DIR/iOS-simulator-lib"
cp -R "$OUT_DIR/iOS-arm64-device/$FRAMEWORK_NAME.framework" "$OUT_DIR/iOS-device-lib/$FRAMEWORK_NAME.framework"
cp -R "$OUT_DIR/iOS-arm64-simulator/$FRAMEWORK_NAME.framework" "$OUT_DIR/iOS-simulator-lib/$FRAMEWORK_NAME.framework"
lipo -create -output "$OUT_DIR/iOS-simulator-lib/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" \
  "$OUT_DIR/iOS-arm64-simulator/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" \
  "$OUT_DIR/iOS-x64-simulator/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"
end_group

start_group "Creating XCFramework"
rm -rf "$OUT_DIR/$FRAMEWORK_NAME.xcframework"
xcodebuild -create-xcframework \
  -framework "$OUT_DIR/iOS-device-lib/$FRAMEWORK_NAME.framework" \
  -framework "$OUT_DIR/iOS-simulator-lib/$FRAMEWORK_NAME.framework" \
  -output "$OUT_DIR/$FRAMEWORK_NAME.xcframework"
cp LICENSE "$OUT_DIR/$FRAMEWORK_NAME.xcframework/"
(cd "$OUT_DIR" && rm -f "$FRAMEWORK_NAME.xcframework.zip" && zip --symlinks -9 -q -r "$FRAMEWORK_NAME.xcframework.zip" "$FRAMEWORK_NAME.xcframework")
end_group

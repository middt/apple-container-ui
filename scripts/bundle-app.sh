#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Vessel"
EXEC_NAME="Vessel"
BUNDLE_DIR="dist/${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Creating macOS App Bundle at ${BUNDLE_DIR}..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

echo "==> Compiling ${EXEC_NAME} (Native arm64 Release, SwiftUI + Charts)..."
find Sources -name "*.swift" -exec touch {} +
sleep 1
swiftc -O -whole-module-optimization \
    -target arm64-apple-macos15.0 \
    -parse-as-library \
    Sources/AppleContainerUI/AppleContainerUIApp.swift \
    Sources/AppleContainerUI/Models/AppLocalization.swift \
    Sources/AppleContainerUI/Models/ContainerModels.swift \
    Sources/AppleContainerUI/Services/AppSettings.swift \
    Sources/AppleContainerUI/Services/ShellWords.swift \
    Sources/AppleContainerUI/Services/MiniYAML.swift \
    Sources/AppleContainerUI/Services/ContainerCLIService.swift \
    Sources/AppleContainerUI/Services/ContainerRuntime.swift \
    Sources/AppleContainerUI/Services/CLIOutputParsers.swift \
    Sources/AppleContainerUI/Services/ComposeOrchestrator.swift \
    Sources/AppleContainerUI/Services/DockerCommandTranslator.swift \
    Sources/AppleContainerUI/Services/ContainerStore.swift \
    Sources/AppleContainerUI/Services/ContainerStore+Actions.swift \
    Sources/AppleContainerUI/Services/ContainerStore+Compose.swift \
    Sources/AppleContainerUI/Services/ContainerStore+Live.swift \
    Sources/AppleContainerUI/Services/ContainerStore+Groups.swift \
    Sources/AppleContainerUI/Views/Components/TelemetryCharts.swift \
    Sources/AppleContainerUI/Views/ContainersSplitView.swift \
    Sources/AppleContainerUI/Views/ContainerGroupViews.swift \
    Sources/AppleContainerUI/Views/ComposeStacksView.swift \
    Sources/AppleContainerUI/Views/DashboardView.swift \
    Sources/AppleContainerUI/Views/MainWindowView.swift \
    Sources/AppleContainerUI/Views/NewContainerSheet.swift \
    Sources/AppleContainerUI/Views/ResourcesViews.swift \
    -o "${MACOS_DIR}/${EXEC_NAME}"

chmod +x "${MACOS_DIR}/${EXEC_NAME}"

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Vessel — Apple Container Studio</string>
    <key>CFBundleIdentifier</key>
    <string>com.vessel.applecontainer.studio</string>
    <key>CFBundleVersion</key>
    <string>1.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${EXEC_NAME}</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Vessel asks Terminal to open an interactive shell inside a container.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

# Code signing.
#   Default: ad-hoc signature ("-"), enough to run locally on Apple Silicon.
#   Distribution: VESSEL_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./scripts/bundle-app.sh
#   signs with the hardened runtime; notarize the result with `xcrun notarytool` afterwards.
SIGN_IDENTITY="${VESSEL_SIGN_IDENTITY:--}"
if [ "${SIGN_IDENTITY}" = "-" ]; then
    echo "==> Signing (ad-hoc)..."
    codesign --force --sign - "${BUNDLE_DIR}"
else
    echo "==> Signing with '${SIGN_IDENTITY}' (hardened runtime)..."
    codesign --force --timestamp --options runtime \
        --entitlements "$(dirname "$0")/Vessel.entitlements" \
        --sign "${SIGN_IDENTITY}" "${BUNDLE_DIR}"
fi
codesign --verify --strict "${BUNDLE_DIR}"

echo "==> Done! Native macOS App bundle created at: $(pwd)/${BUNDLE_DIR}"
echo "    Launch with: open ${BUNDLE_DIR}"

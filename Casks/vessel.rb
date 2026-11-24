cask "vessel" do
  version "1.1.0"
  sha256 "a73db799c5dca1719ea0768710f091079fe5c0699c39cb189701cf4f3d879bc2"

  url "https://github.com/middt/apple-container-ui/releases/download/v#{version}/Vessel-v#{version}-macos-arm64.zip"
  name "Vessel"
  desc "Native macOS Container Studio for Apple Container (Virtualization.framework) & Docker Compose"
  homepage "https://github.com/middt/apple-container-ui"

  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "Vessel.app"
  binary "#{appdir}/Vessel.app/Contents/MacOS/Vessel", target: "vessel"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Vessel.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.vessel.applecontainer.studio.plist",
    "~/Library/Saved Application State/com.vessel.applecontainer.studio.savedState",
  ]
end

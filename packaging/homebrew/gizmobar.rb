cask "gizmobar" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/thomasmelak/gizmobar/releases/download/v#{version}/Gizmobar-#{version}.zip"
  name "Gizmobar"
  desc "Native status bar with AeroSpace workspaces, plugins and 3D models"
  homepage "https://thomasmelak.github.io/gizmobar/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Gizmobar.app"
  binary "#{appdir}/Gizmobar.app/Contents/MacOS/gizmo"

  # Releases are ad-hoc signed until a Developer ID is set up, so Gatekeeper
  # would refuse to open the downloaded app. Clear the quarantine flag.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Gizmobar.app"]
  end

  uninstall quit: "io.thomasmelak.gizmobar"

  zap trash: [
    "~/Library/Application Support/Gizmobar",
    "~/Library/Preferences/io.thomasmelak.gizmobar.plist",
  ]

  caveats <<~EOS
    Copy the example config into ~/.config/gizmobar (never overwrites):
      gizmo config init
    Then start the bar:
      open -a Gizmobar
  EOS
end

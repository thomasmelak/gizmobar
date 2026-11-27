cask "gizmobar" do
  version :latest
  sha256 :no_check

  url "https://github.com/thomasmelak/gizmobar/releases/latest/download/Gizmobar.zip"
  name "Gizmobar"
  desc "Native status bar with AeroSpace workspaces, plugins and 3D models"
  homepage "https://thomasmelak.github.io/gizmobar/"

  depends_on macos: ">= :sonoma"

  app "Gizmobar.app"
  binary "#{appdir}/Gizmobar.app/Contents/MacOS/gizmo"

  # Releases are ad-hoc signed, not notarized: clear the quarantine flag so
  # Gatekeeper opens the app, then start it.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Gizmobar.app"]
    system_command "/usr/bin/open", args: ["#{appdir}/Gizmobar.app"]
  end

  caveats <<~EOS
    Copy the example config into ~/.config/gizmobar (never overwrites):
      gizmo config init
  EOS

  uninstall quit: "io.thomasmelak.gizmobar"

  zap trash: [
    "~/Library/Application Support/Gizmobar",
    "~/Library/Preferences/io.thomasmelak.gizmobar.plist",
  ]
end

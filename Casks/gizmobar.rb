cask "gizmobar" do
  version "0.2.0"
  sha256 "3d04b2f962a2e2b74e8a20fd85f38ddb4695c065d067d297851a8eda7c779f66"

  url "https://github.com/thomasmelak/gizmobar/releases/download/v#{version}/Gizmobar.zip"
  name "Gizmobar"
  desc "Native status bar with AeroSpace workspaces, plugins and 3D models"
  homepage "https://thomasmelak.github.io/gizmobar/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Gizmobar.app"
  binary "#{appdir}/Gizmobar.app/Contents/MacOS/gizmo"

  # Releases are not notarized: clear the quarantine flag so
  # Gatekeeper opens the app, then start it.
  postflight_steps do
    run "/usr/bin/xattr",
        args:         ["-dr", "com.apple.quarantine", "{{appdir}}/Gizmobar.app"],
        must_succeed: false
    run "/usr/bin/open",
        args:         ["{{appdir}}/Gizmobar.app"],
        must_succeed: false
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

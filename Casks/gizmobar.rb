cask "gizmobar" do
  version "0.1.1"
  sha256 "3ccdb3c49290c3f904dfd58e00f2e9a99969305cf61bf3e21824fb81eb8568e1"

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

cask "plezy" do
  version "1.31.3"
  sha256 "d57abe37df0f821bad3d9688f20ad858d01a5d23a582b4244fa9541ef49face1"

  url "https://github.com/edde746/plezy/releases/download/#{version}/plezy-macos.dmg"
  name "Plezy"
  desc "Modern Plex client built with Flutter"
  homepage "https://github.com/edde746/plezy"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true

  app "Plezy.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/Plezy.app"],
                   sudo: false
  end

  uninstall quit: "de.aryanmo.oxplayer"

  zap trash: [
    "~/Library/Application Support/de.aryanmo.oxplayer",
    "~/Library/Caches/de.aryanmo.oxplayer",
    "~/Library/HTTPStorages/de.aryanmo.oxplayer",
    "~/Library/Preferences/de.aryanmo.oxplayer.plist",
    "~/Library/Saved Application State/de.aryanmo.oxplayer.savedState",
    "~/Library/WebKit/de.aryanmo.oxplayer",
  ]
end

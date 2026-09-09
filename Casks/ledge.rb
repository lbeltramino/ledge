cask "ledge" do
  version "0.11.1"
  sha256 "49196830b4d21ac62b2b9500cb016928d18bf3354819b546c9e53b9ee3677f73"

  url "https://github.com/lbeltramino/ledge/releases/download/v#{version}/Ledge-v#{version}.zip"
  name "Ledge"
  desc "Notes docked to the edge of your screen, as plain Markdown files"
  homepage "https://github.com/lbeltramino/ledge"

  # This build is not notarised. Homebrew quarantines what it downloads and
  # current versions offer no supported way around it, so after installing:
  #
  #   xattr -dr com.apple.quarantine /Applications/Ledge.app
  #
  # That is you vouching for an app Apple has not checked. Nothing in this cask
  # does it on your behalf, and nothing should.
  app "Ledge.app"
  # The command-line half, for scripts and agents. It lives inside the bundle so
  # it carries the app's signature; this is what puts it on the PATH as `ledge`.
  binary "#{appdir}/Ledge.app/Contents/MacOS/ledge-cli", target: "ledge"

  zap trash: [
    "~/Library/Preferences/com.lisandro.Ledge.plist",
  ]
  # Your notes are plain files in ~/Documents/Ledge and are never removed.
end

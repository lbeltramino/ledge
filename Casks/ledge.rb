cask "ledge" do
  version "0.7.0"
  sha256 "53f7c2761e98c3f4075700723863b551fc4f8e2e489eb24d4afda45fe43e8002"

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

  zap trash: [
    "~/Library/Preferences/com.lisandro.Ledge.plist",
  ]
  # Your notes are plain files in ~/Documents/Ledge and are never removed.
end

cask "ledge" do
  version "0.4.0"
  sha256 "c02f798f1078bccd6a7410b1d12097c4da034566f44a87de712bcea9a1e42a49"

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

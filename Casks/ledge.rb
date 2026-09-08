cask "ledge" do
  version "0.4.0"
  sha256 "c02f798f1078bccd6a7410b1d12097c4da034566f44a87de712bcea9a1e42a49"

  url "https://github.com/lbeltramino/ledge/releases/download/v#{version}/Ledge-v#{version}.zip"
  name "Ledge"
  desc "Notes docked to the edge of your screen, as plain Markdown files"
  homepage "https://github.com/lbeltramino/ledge"

  # This build is not notarised. Homebrew quarantines downloads by default, and
  # a quarantined build that Apple cannot check will not open — so installing it
  # means passing --no-quarantine, which is you vouching for it. Nothing here
  # does that on your behalf.
  app "Ledge.app"

  zap trash: [
    "~/Library/Preferences/com.lisandro.Ledge.plist",
  ]
  # Your notes are plain files in ~/Documents/Ledge and are never removed.
end

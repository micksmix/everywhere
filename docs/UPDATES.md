# Publishing app updates

Everywhere uses Sparkle 2 to verify, install, and relaunch GitHub release updates.
The feed URL is `https://github.com/micksmix/everywhere/releases/latest/download/appcast.xml`.
Each stable release must include this feed and its referenced universal app zip.
Pre-releases are not offered through this URL. Keep the latest release compatible
with macOS 13; if the minimum OS changes, preserve older compatible entries in the
feed before publishing that release.

## One-time signing setup

A dedicated Ed25519 signing key was generated in the development Mac's login
Keychain under Sparkle's account `app.everywhere.macos`. Its public key is in
`Info.plist` as `SUPublicEDKey`. The private key is not in the repository.
This signature is separate from Apple's code signing; the app remains signed ad hoc.

Back up the private key securely and configure the GitHub Actions secret before
pushing the first release tag with this integration. From the repository directory:

```sh
swift package resolve
umask 077
key_file=$(mktemp -t everywhere-sparkle)
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account app.everywhere.macos -x "$key_file"
gh secret set SPARKLE_PRIVATE_KEY --repo micksmix/everywhere < "$key_file"
rm "$key_file"
```

The `gh` login needs permission to manage this repository's Actions secrets. You
can instead paste the exported file's contents into **Repository Settings → Secrets
and variables → Actions → New repository secret**, named `SPARKLE_PRIVATE_KEY`.
Never commit, log, or publish the private key. Keep a secure backup before deleting
an exported copy. The Keychain original remains available after deleting the file.
Do not generate a replacement key once an update-enabled build has shipped: installed
copies trust the original public key, and ad-hoc signed apps cannot use Developer ID
as a fallback to recover a lost signing key.

On another development Mac, ordinary builds only need the committed public key.
For signing locally, import a securely transferred private key with Sparkle's
`generate_keys --account app.everywhere.macos -f /path/to/private-key`.

## Release workflow

Run `make release VERSION=x.y.z` after committing the changes and setting the secret.
Use an increasing three-component version. Both `CFBundleVersion` and
`CFBundleShortVersionString` are set from Makefile's version during bundling.

GitHub Actions tests and builds the universal app, generates an appcast using the
secret on standard input, and verifies the archive's signature against the public
key embedded in the built app before publishing. The release includes the app zip,
SHA256 file, and `appcast.xml`. Homebrew continues to use the same zip.
A retry uses the already published zip when regenerating its feed, so it never
signs a different rebuild while pointing at an existing asset. The signing step
fails when the secret is missing or does not match the bundle's public key.

Do not replace a published zip or delete the latest release's appcast. Publish a new
version instead. Releases made outside Actions must also include a signed appcast;
otherwise installed copies cannot discover them. Existing installations without
Sparkle require one manual upgrade to gain in-app updates.

## Local verification

```sh
make test
make dist
feed_dir=$(mktemp -d -t everywhere-appcast)
cp .build/Everywhere-1.0.0.zip "$feed_dir/"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --account app.everywhere.macos --maximum-deltas 0 \
  --download-url-prefix https://github.com/micksmix/everywhere/releases/download/v1.0.0/ \
  "$feed_dir"
python3 Scripts/verify-appcast.py "$feed_dir/appcast.xml" "$feed_dir/Everywhere-1.0.0.zip"
```

Substitute the current version. For an end-to-end install test, use two disposable
bundled app versions with a local test feed, isolated preferences and index storage,
and a test signing key. Verify a newer signed update installs and relaunches, a
modified archive is rejected, disabling automatic checks suppresses launch checks,
and a manual check still works. Do not test replacement against a user's installed
copy or use the real index. Plain `swift run` disables update controls because it
is not an app bundle.

See [Sparkle setup](https://sparkle-project.org/documentation/) and
[publishing updates](https://sparkle-project.org/documentation/publishing/).

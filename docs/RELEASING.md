# Release guide

A release is a `v`-tagged commit. GitHub Actions builds the universal zip,
publishes it as a GitHub release on this repository, and updates the tap's
cask. Publishing is one command:

```sh
make release VERSION=x.y.z
```

The target performs these steps in order:

1. Requires a clean working tree (including staged and untracked files), a new
   tag, and a version with three numbers. Commit the workflow and other changes first.
2. Runs the test suite; a failure stops the release.
3. Sets the version in the Makefile (`make bump VERSION=x.y.z`).
4. Commits the version change if needed, tags `vx.y.z`, and pushes the tag.

The tag push triggers the release workflow (`.github/workflows/release.yml`),
which runs the tests again, builds one universal app for ARM64 and Intel x86_64
using `swift build --arch arm64 --arch x86_64`, and verifies both architectures
and the ad-hoc signature. The app targets macOS 13 or later. It publishes
the tagged release with the zip, a SHA256 checksum file, and auto-generated notes,
then updates
`Casks/everywhere.rb` in `micksmix/homebrew-tap` with the matching version and
SHA256 calculated from the publicly downloaded release asset. Watch progress
under the repo's **Actions** tab. The tap job is separate: if it fails, fix the
secret or tap permissions and choose **Re-run failed jobs**. Rerunning the whole
workflow keeps an existing published zip and uses its checksum; it does not
replace release assets. Older releases do not overwrite the latest tap version.

Finish by pushing the main branch, which the target deliberately leaves to you:

```sh
git push
```

Verify through Homebrew: `brew install --cask micksmix/tap/everywhere` (or
`brew upgrade --cask micksmix/tap/everywhere` for existing installs).
`brew livecheck --cask micksmix/tap/everywhere` checks for upstream releases;
it does not install updates or edit the cask.

### Release authentication and one-time setup

GitHub Actions builds and publishes the release after a tag is pushed. Your
local Git credentials need permission to push that tag, but your local `gh`
login is not used by the workflow. Both the source repository and the tap
should be public so Homebrew users can download the release without credentials.
Enable GitHub Actions in `micksmix/everywhere` before the first release.
Configure the `SPARKLE_PRIVATE_KEY` repository secret using the [update release setup](UPDATES.md) before publishing an update-enabled build. Each release includes a signed `appcast.xml` alongside the universal zip.

The build needs no personal access token. Publishing the zip to
`micksmix/everywhere` uses GitHub's automatically supplied `GITHUB_TOKEN`, with
`contents: write` granted by the workflow. That token is scoped to the
repository running the workflow, so it cannot also push changes to the separate
`micksmix/homebrew-tap` repository. The workflow uses `TAP_TOKEN` for that push.

Create the token in the tap owner's GitHub account (`micksmix`):

1. Open your account's **Settings → Developer settings → Personal access tokens
   → Fine-grained tokens**, then choose **Generate new token**.
2. Give it a descriptive name, choose an expiration, and set the resource owner
   to **micksmix**.
3. Under **Repository access**, choose **Only select repositories** and select
   **micksmix/homebrew-tap**.
4. Under **Repository permissions → Add permissions**, search for and select
   **Contents**, then set its access to **Read and write**.
5. Leave **Metadata → Read-only** if GitHub adds it automatically. No other
   repository or account permissions are needed, including Actions,
   Administration, and Workflows.
6. Click **Generate token** and copy the generated value.

Save the value in the **Everywhere repository**, where the workflow runs:

1. Open **micksmix/everywhere → Settings → Secrets and variables → Actions**.
2. Under **Repository secrets**, click **New repository secret**.
3. Set **Name** to `TAP_TOKEN` and **Secret** to the generated token value,
   then save it.

Use a **repository secret**, not an environment secret or an Actions variable.
The workflow reads `${{ secrets.TAP_TOKEN }}` and does not declare a deployment
`environment`, so an environment secret would not be available to it. The token
is scoped to the tap, but the secret belongs in Everywhere, not in the tap.

The tap's branch rules must allow the token owner's direct push. Renew the
repository secret before the token expires. If the tap update fails after the
release is published, correct the secret or permissions and choose
**Re-run failed jobs** in the release's Actions run.

Commit and push the workflow, Makefile, and documentation before running
`make release VERSION=x.y.z`. No local checkout of the tap is required for
this Actions workflow; it checks out `micksmix/homebrew-tap` itself.

`TAP_TOKEN` is unnecessary if you update the cask manually. A GitHub App
installation token or a write-enabled deploy key can replace the PAT with
corresponding workflow changes. See GitHub's
[workflow authentication documentation](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token).

The release app is signed ad hoc and is not notarized. Homebrew installation
can succeed while macOS still requires approval on first launch; see Apple's
[opening apps safely](https://support.apple.com/en-us/102445) guidance.
To change the version without releasing, use `make bump VERSION=x.y.z`.

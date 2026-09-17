# Everywhere website

The GitHub Pages showcase lives in `site/`. It is plain HTML, CSS, and JavaScript,
with no build step or external runtime dependencies.

## Preview locally

From the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory site
```

Open http://127.0.0.1:8765. The clipboard button works on localhost and HTTPS.

## Publish to GitHub Pages

1. Commit `site/`, `.github/workflows/pages.yml`, and this documentation, then push to `main`.
2. As a repository administrator, open **Settings → Pages** and set **Source** to **GitHub Actions**.
3. Run **Actions → Deploy website to GitHub Pages → Run workflow** on `main`.
4. Follow the deployment URL in the successful workflow. The expected default address is
   https://micksmix.github.io/everywhere/.

Subsequent pushes to `main` that change the site or workflow deploy automatically.
Only `site/` is uploaded, not the app source, docs, or local build output.
The workflow follows [GitHub's custom Pages workflow documentation](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

## Screenshots and editing

- `site/assets/search.png`: actual Everywhere window, searching Swift files in this project's Sources folder.
- `site/assets/filtered-search.png`: actual Everywhere window, narrowing that folder to names containing Search.
- `site/assets/icon.svg`: copy of the app's vector icon from `Resources/AppIcon.svg`.

Screenshots were captured on September 16, 2026, from the running app. They use this
project's files rather than unrelated personal files. Displayed counts and times are
specific to these searches and are not published as benchmark claims.

Update copy in `site/index.html`, styles in `site/style.css`, and the copy button in
`site/script.js`. Keep image links relative so the site works under the repository's
`/everywhere/` path. Open the screenshot links to see them at full size.

Before publishing edits, check desktop and narrow mobile layouts, the Homebrew copy
button, local asset loading, and destination links. Run `make test` as required by
repository guidance.

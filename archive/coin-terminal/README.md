# Archived: 3D Coin Terminal

Removed from the Terminal page (`#terminal`) and kept here in case it comes back. This folder is outside `public/`, so it is not deployed.

- `coin-terminal-standalone.html` – the 3D terminal as a standalone page (add `?embed` to hide the drag hint).
- `coin-terminal-front@2x.png` – its loading poster.
- `strategy-page-3d-markup.html` – the old Strategy page markup from the site template (sticky hero with the iframe and poster background, plus the data cards).

To restore: copy the two files back into `public/` (`public/assets/` for the poster), re-embed the standalone page in the bundle as a nested page (an `about:blank#<uuid>` iframe marker + `__bundler/page_order` entry) and re-add the poster as a bundle asset, then reinstate the markup above. The old placeholder data lives in git history.

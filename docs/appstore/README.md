# App Store material

| File | What |
| --- | --- |
| [privacy-policy.md](privacy-policy.md) | The privacy policy at the URL App Store Connect has. The GitHub Pages copy is [`docs/privacy/index.html`](../privacy/index.html): keep both identical, with the same date. |
| [screenshots.md](screenshots.md) | Generated screenshots (`scripts/screenshots.sh`): sizes, shot list, demo vault |
| [eula.md](eula.md) | Custom license agreement for App Store Connect |

Before each submission, run `scripts/release-check.sh` (`just release-check`; CI runs it too). The submission
itself (build, What's New, privacy answers, review, release) is step B.5 of [releasing.md](../releasing.md); the site with `/privacy` and `/support` goes live first (B.4).

# No Gitea workflows

CI runs on GitHub Actions (`.github/workflows/`, see `docs/ci.md`). Gitea is a mirror.

This folder exists so Gitea Actions finds no workflows here and does not fall back to
`.github/workflows/`, which it does when `.gitea/workflows/` is missing. Keep it, and keep
it free of workflow files.

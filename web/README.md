# Sempere web viewer

Read-only, static viewer for Sempere vaults with decryption in the browser.
See [`docs/web-viewer.md`](../docs/web-viewer.md) for what it does, the threat
model, hosting (static files with `sempere vault index`, or a WebDAV mirror
made by `sempere sync webdav`), limits and tests.

```bash
npm ci
npm run dev        # http://localhost:5173
npm test           # includes the cross-check against the Swift CLI's exports
npm run build      # dist/: copy it to any static host
```

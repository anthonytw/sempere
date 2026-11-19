// The Content-Security-Policy of a share file (docs/design/1.3-share.md §3.1, D8). It sits in a <meta> in the
// file itself, so it travels with the page; the script and the style are pinned by their SHA-256, and nothing
// may be fetched or sent (`connect-src 'none'`). The Swift side (`sempere share --verify`) compares the whole
// template, this meta included, to the one it ships.

export function shareContentSecurityPolicy(scriptSha256Base64: string, styleSha256Base64: string): string {
  return [
    "default-src 'none'",
    `script-src 'sha256-${scriptSha256Base64}'`,
    `style-src 'sha256-${styleSha256Base64}'`,
    "img-src data: blob:",
    "media-src blob:",
    "connect-src 'none'",
    "worker-src blob:",
    "base-uri 'none'",
    "form-action 'none'",
    "object-src 'none'",
    "frame-src 'none'",
    "manifest-src 'none'",
    "require-trusted-types-for 'script'",
    "trusted-types sempere-share-worker",
  ].join("; ");
}

// Entry point of a share file's script. The same script runs twice: in the page (it has a `document`), and in
// the scrypt worker the page starts from a copy of it (no `document`): see src/share/worker.ts.

import "../style.css";
import "./share.css";
import { initLocale } from "../i18n/index.ts";
import { ShareApp } from "../ui/shareapp.ts";
import { serve } from "./worker.ts";

if (typeof document === "undefined") {
  serve(globalThis as unknown as Parameters<typeof serve>[0]);
} else {
  // Read first: only the script that is executing has a `currentScript`.
  const self = document.currentScript;
  initLocale();
  // The page's title never carries the note's (D7); the viewer's own title says what it is.
  document.title = "Shared note";
  const root = document.getElementById("app");
  const data = document.getElementById("share-data");
  if (root && data) {
    new ShareApp(root, { data: data.textContent ?? "", workerSource: self?.textContent ?? undefined, print: () => window.print() }).start();
  }
}

// The screen after a pasted key unlocked with "remember" ticked (src/ui/passkey.ts `rememberScreen`),
// on a minimal stand-in for the DOM: the unit tests run in Node.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { rememberScreen } from "../src/ui/passkey.ts";
import type { PasskeyVault } from "../src/vault/passkey.ts";

/** Just enough of an element for `h` and the screen's handlers. */
class FakeElement {
  className = "";
  textContent = "";
  title = "";
  disabled = false;
  readonly children: FakeElement[] = [];
  readonly attributes = new Map<string, string>();
  private readonly listeners = new Map<string, (() => void)[]>();
  constructor(readonly tag: string) {}
  setAttribute(k: string, v: string): void { this.attributes.set(k, v); }
  removeAttribute(k: string): void { this.attributes.delete(k); }
  addEventListener(k: string, f: () => void): void { this.listeners.set(k, [...this.listeners.get(k) ?? [], f]); }
  append(c: FakeElement | string): void { if (typeof c !== "string") this.children.push(c); }
  focus(): void {}
  click(): void { for (const f of this.listeners.get("click") ?? []) f(); }
  /** Every element below this one, depth first. */
  all(): FakeElement[] { return this.children.flatMap((c) => [c, ...c.all()]); }
}

beforeEach(() => {
  vi.stubGlobal("document", { createElement: (tag: string) => new FakeElement(tag) });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function deferred(): { promise: Promise<void>; resolve: () => void; reject: (e: unknown) => void } {
  let resolve!: () => void, reject!: (e: unknown) => void;
  const promise = new Promise<void>((y, n) => { resolve = y; reject = n; });
  return { promise, resolve, reject };
}

function screen(remember: () => Promise<void>, done: () => void): { create: FakeElement; skip: FakeElement; status: FakeElement } {
  const pv = { remember } as unknown as PasskeyVault;
  const root = rememberScreen(pv, "AGE-SECRET-KEY-PQ-1X", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "https://notes.example/vault/",
    "Notes", done) as unknown as FakeElement;
  const buttons = root.all().filter((e) => e.tag === "button");
  const status = root.all().find((e) => e.attributes.get("role") === "status");
  if (buttons.length !== 2 || !status) throw new Error("unexpected screen");
  return { create: buttons[0] as FakeElement, skip: buttons[1] as FakeElement, status };
}

describe("remember screen", () => {
  it("finishes once when Not now is pressed while the passkey prompt is open (bug audit B52)", async () => {
    for (const outcome of ["resolve", "reject"] as const) {
      const pending = deferred();
      let done = 0;
      const { create, skip, status } = screen(() => pending.promise, () => { done += 1; });
      create.click();
      skip.click();
      expect(done).toBe(1);
      if (outcome === "resolve") pending.resolve();
      else pending.reject(new Error("cancelled"));
      await new Promise((r) => setTimeout(r, 0));
      expect(done, outcome).toBe(1);
      expect(status.className, outcome).not.toBe("error");
    }
  });

  it("finishes once after the passkey is created, and lets the user go on after a failure", async () => {
    let done = 0;
    const ok = screen(() => Promise.resolve(), () => { done += 1; });
    ok.create.click();
    await new Promise((r) => setTimeout(r, 0));
    expect(done).toBe(1);
    ok.skip.click();
    expect(done).toBe(1);

    done = 0;
    const failed = screen(() => Promise.reject(new Error("no")), () => { done += 1; });
    failed.create.click();
    await new Promise((r) => setTimeout(r, 0));
    expect(done).toBe(0);
    expect(failed.status.className).toBe("error");
    expect(failed.create.disabled).toBe(false);
    failed.skip.click();
    expect(done).toBe(1);
  });
});

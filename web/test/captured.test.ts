// Capture attribution in the viewer (format.md §8.3.1 `captured`; security
// review 2026-10 stage 4, S10): mirrors the app's
// RecipientsAlertTests.capturedByNamesTheDevice and the core's
// CaptureAttributionTests.testMalformedAttributionReadsAsAbsent.

import { describe, expect, it } from "vitest";
import { checkRecordingChange } from "../src/format/attachments.ts";
import { type CapturedBy, capturedBy, decodeCaptured, recipientFingerprint } from "../src/format/captured.ts";
import { recordingRegisters } from "../src/format/registers.ts";
import { capturedText } from "../src/ui/recordings.ts";

const key = "age1pq1synthetickey";
/** The text shown for `by`, which must be a capture. */
function text(by: CapturedBy | undefined): string {
  if (!by) throw new Error("not a capture");
  return capturedText(by);
}

const fingerprint = "cf5399cc2f0cb4f1cde172cebe02e5033a82c9641e8e135acba1fede6f85d966";

describe("captured", () => {
  it("fingerprints a recipient as format.md §11.1 does (SHA-256 hex of the key text)", async () => {
    expect(await recipientFingerprint(key)).toBe(fingerprint);
  });

  it("names the device that captured a voice note, as the app does", async () => {
    const entries = [{ key, label: "iPad" }];
    const rec = { id: "r", captured: { device: "0b0b0b0b", recipient: fingerprint } };
    expect(await capturedBy({ id: "r" }, entries)).toBeUndefined();
    const by = await capturedBy(rec, entries);
    expect(by).toEqual({ kind: "device", label: "iPad" });
    expect(text(by)).toBe("Voice note from iPad");
    expect(text(await capturedBy(rec, []))).toBe("Voice note from a device no longer in this vault");
    expect(text(await capturedBy(rec, [{ key, label: "" }]))).toBe("Voice note from Device");
    const unattributed = { id: "r", captured: { device: "0b0b0b0b" } };
    expect(text(await capturedBy(unattributed, entries))).toBe("Voice note from an unverified device");
    expect(text(await capturedBy({ captured: { device: "0b0b0b0b", recipient: null } }, entries)))
      .toBe("Voice note from an unverified device");
  });

  it("reads a malformed attribution as absent, never as an error", () => {
    for (const bad of [null, 3, "0b0b0b0b", [], {}, { device: "0B0B0B0B" }, { device: "0b0b0b0" },
      { device: 12345678 }, { device: "0b0b0b0b", recipient: "abc" }, { device: "0b0b0b0b", recipient: 7 },
      { device: "0b0b0b0b", recipient: fingerprint.toUpperCase() }]) {
      expect(decodeCaptured(bad), JSON.stringify(bad)).toBeUndefined();
    }
    expect(decodeCaptured({ device: "0b0b0b0b", recipient: fingerprint, extra: 1 }))
      .toEqual({ device: "0b0b0b0b", recipient: fingerprint });
  });

  it("is immutable, as in Swift: a setRecording cannot rewrite who captured a note", () => {
    expect(() => checkRecordingChange("captured", { device: "0c0c0c0c" }, "$.ops[0].value")).toThrow(/immutable/);
    const regs = recordingRegisters({ id: "r", captured: { device: "0b0b0b0b" }, title: "t" });
    expect(regs.has("captured")).toBe(false);
  });
});

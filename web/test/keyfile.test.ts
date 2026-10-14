// Passphrase-wrapped keys (format.md §3.2): the sample vault's stored key file
// and a paper kit's armored passphrase copy, both written by the Swift CLI
// (passphrase `sempere-test`, work factor 15; Tests/SempereTests/Fixtures/README.md).

import { Encrypter, armor } from "age-encryption";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { KeyFileError, keyFileName, looksArmored, looksWrapped, maxWorkFactor, unwrapKey, workFactor, wrappedBytes } from "../src/vault/keyfile.ts";
import { UnlockedVault, parseManifest } from "../src/vault/vault.ts";
import { fixtures, sampleIdentity, webFixtures } from "./support.ts";

const vaultDir = join(fixtures, "sample.sempere");
const manifest = parseManifest(new Uint8Array(readFileSync(join(vaultDir, "vault.json"))));
const storedName = readdirSync(join(vaultDir, "keys"))[0] ?? "";
const stored = new Uint8Array(readFileSync(join(vaultDir, "keys", storedName)));
const kit = readFileSync(join(webFixtures, "paper-kit-passphrase.txt"), "utf8");

async function code(p: Promise<unknown>): Promise<string> {
  try {
    await p;
  } catch (e) {
    if (e instanceof KeyFileError) return e.code;
    throw e;
  }
  return "ok";
}

async function wrapped(plain: string, logN = 10): Promise<Uint8Array> {
  const e = new Encrypter();
  e.setPassphrase("pw");
  e.setScryptWorkFactor(logN);
  return e.encrypt(plain);
}

describe("passphrase-wrapped keys", () => {
  it("names the stored key file as Swift does", async () => {
    const [r] = manifest.recipients;
    expect(await keyFileName(r?.key ?? "")).toBe(storedName);
    expect(await keyFileName("age1abc")).toBe("age1abc.key.age");
  });

  it("opens the vault's stored key file with its passphrase", async () => {
    expect(looksWrapped(stored)).toBe(true);
    expect(workFactor(wrappedBytes(stored))).toBe(15);
    const identity = await unwrapKey(wrappedBytes(stored), "sempere-test");
    expect(identity).toBe(sampleIdentity());
    const vault = await UnlockedVault.unlock(manifest, identity);
    expect(vault.manifest.vaultId).toBe(manifest.vaultId);
  });

  it("opens a paper kit's armored copy, also pasted with indentation, blank lines and CRLF", async () => {
    expect(looksArmored(kit)).toBe(true);
    expect(await unwrapKey(wrappedBytes(kit), "sempere-test")).toBe(sampleIdentity());
    const sloppy = "Key:\r\n" + kit.split("\n").map((l) => `   ${l}  `).join("\r\n\r\n");
    expect(await unwrapKey(wrappedBytes(sloppy), "sempere-test")).toBe(sampleIdentity());
  });

  it("refuses a wrong passphrase, and an empty one", async () => {
    expect(await code(unwrapKey(wrappedBytes(stored), "sempere-tesT"))).toBe("wrongPassphrase");
    expect(await code(unwrapKey(wrappedBytes(stored), ""))).toBe("wrongPassphrase");
  });

  it("refuses a damaged armor with a hint to check the lines", () => {
    const lines = kit.split("\n");
    lines[2] = (lines[2] ?? "").slice(0, 60);
    expect(() => wrappedBytes(lines.join("\n"))).toThrow(/checksums/);
  });

  it("refuses files that are not passphrase-wrapped", () => {
    expect(() => wrappedBytes(new TextEncoder().encode("AGE-SECRET-KEY-PQ-1..."))).toThrow(KeyFileError);
    const notes = readdirSync(join(vaultDir, "notes"));
    const dir = join(vaultDir, "notes", notes[0] ?? "");
    const rev = new Uint8Array(readFileSync(join(dir, readdirSync(dir).find((f) => f.endsWith(".age")) ?? "")));
    expect(() => workFactor(rev)).toThrow(/not with a passphrase/);
    expect(() => wrappedBytes(new Uint8Array(70_000))).toThrow(/64 KiB/);
  });

  it(`refuses a work factor over ${maxWorkFactor} before any scrypt work`, async () => {
    const file = await wrapped("x", 10);
    const text = new TextDecoder("latin1").decode(file).replace(/^(-> scrypt \S+) 10$/m, "$1 21");
    const raised = Uint8Array.from(text, (c) => c.charCodeAt(0));
    expect(() => workFactor(raised)).toThrow(/work factor is 21/);
    expect(await code(unwrapKey(raised, "pw"))).toBe("workFactor");
  });

  it("refuses a decrypted file that holds no post-quantum key", async () => {
    expect(await code(unwrapKey(await wrapped("hello"), "pw"))).toBe("noKey");
    expect(await code(unwrapKey(await wrapped("AGE-SECRET-KEY-1QQQQ"), "pw"))).toBe("noKey");
    expect(await code(unwrapKey(await wrapped("x".repeat(20_000)), "pw"))).toBe("noKey");
    const armored = armor.encode(await wrapped(`# comment\n${sampleIdentity()}\n`));
    expect(await unwrapKey(wrappedBytes(armored), "pw")).toBe(sampleIdentity());
  });
});

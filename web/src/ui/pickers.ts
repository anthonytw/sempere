// Turning a user's choice into a vault source: a picked directory (File
// System Access API), a folder from `<input webkitdirectory>`, or a dropped
// folder (DataTransferItem.webkitGetAsEntry).

import { t } from "../i18n/index.ts";
import { type DirectoryHandle, DirectorySource, FileListSource, SourceError } from "../vault/source.ts";

/** Most files read from a dropped or picked folder (format.md §9: bound the work). */
const maxFiles = 500_000;

interface PickerWindow {
  showDirectoryPicker?: (opts?: { mode?: "read" }) => Promise<DirectoryHandle>;
}

export function canPickDirectory(): boolean {
  return typeof (window as PickerWindow).showDirectoryPicker === "function";
}

export async function pickDirectory(): Promise<DirectorySource> {
  const pick = (window as PickerWindow).showDirectoryPicker;
  if (!pick) throw new SourceError(t("this browser cannot open folders directly; drop the folder or use the folder picker"));
  return new DirectorySource(await pick.call(window, { mode: "read" }));
}

/** Files from `<input type=file webkitdirectory>`. */
export function fromFileList(files: FileList): FileListSource {
  if (files.length > maxFiles) throw new SourceError(t("the folder has too many files"));
  return FileListSource.fromPaths(Array.from(files, (f) => [f.webkitRelativePath || f.name, f] as [string, File]));
}

async function readAll(dir: FileSystemDirectoryEntry): Promise<FileSystemEntry[]> {
  const reader = dir.createReader();
  const out: FileSystemEntry[] = [];
  for (;;) {
    const batch = await new Promise<FileSystemEntry[]>((resolve, reject) => reader.readEntries(resolve, reject));
    if (batch.length === 0) return out;
    out.push(...batch);
  }
}

function file(entry: FileSystemFileEntry): Promise<File> {
  return new Promise((resolve, reject) => entry.file(resolve, reject));
}

/** Files of a dropped folder, with paths relative to the drop. */
export async function fromDrop(items: DataTransferItemList): Promise<FileListSource> {
  const roots = Array.from(items).map((i) => i.webkitGetAsEntry()).filter((e): e is FileSystemEntry => e !== null);
  const out: [string, File][] = [];
  const walk = async (entry: FileSystemEntry, prefix: string, depth: number): Promise<void> => {
    if (out.length > maxFiles) throw new SourceError(t("the folder has too many files"));
    const path = prefix + entry.name;
    if (entry.isFile) {
      out.push([path, await file(entry as FileSystemFileEntry)]);
    } else if (entry.isDirectory && depth < 8) {
      for (const child of await readAll(entry as FileSystemDirectoryEntry)) await walk(child, `${path}/`, depth + 1);
    }
  };
  for (const r of roots) await walk(r, "", 0);
  return FileListSource.fromPaths(out);
}

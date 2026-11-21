// The share build has no PDF reader (docs/design/1.3-share.md D4): the sender rasterizes PDF pages into
// images, so the note view's PDF path is never taken. This stands in for src/ui/pdf.ts, which would pull in
// pdf.js; every call fails, and an item that still reached it is drawn as a placeholder.

export const maxPDFBytes = 0;

const unavailable = (): Promise<never> => Promise.reject(new Error("PDFs are not part of a shared note"));

export class NotePDFs {
  document(_key: string, _load: () => Promise<Uint8Array>): Promise<never> {
    return unavailable();
  }
  page(_doc: never, _index: number): Promise<never> {
    return unavailable();
  }
  static effectiveSize(_page: never): { w: number; h: number } {
    return { w: 1, h: 1 };
  }
  render(_page: never, _crop: { x: number; y: number; w: number; h: number }, _scale: number, _math: boolean): Promise<never> {
    return unavailable();
  }
  destroy(): void {}
}

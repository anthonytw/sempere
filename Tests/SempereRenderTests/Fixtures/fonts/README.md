Test fonts: subsets of Noto fonts (SIL Open Font License 1.1, `OFL.txt`) made with fontTools'
`pyftsubset` from Debian/Ubuntu's `fonts-noto-core` and `fonts-noto-cjk`, layout features kept:

- `arabic.ttf`: Noto Naskh Arabic Regular, the Arabic test strings of `TextLayoutTests`.
- `hebrew.ttf`: Noto Sans Hebrew Regular, the Hebrew test strings.
- `cjk.otf`: Noto Sans CJK JP Regular (face 0 of `NotoSansCJK-Regular.ttc`, CFF outlines), the CJK test strings;
  used as a font pack (`SEMPERE_FONT_DIR`).

Regenerate:

    pyftsubset /usr/share/fonts/truetype/noto/NotoNaskhArabic-Regular.ttf --text="مرحبا بالعالم لا إله بِسْمِ اللَّهِ ١٢٣ كتاب" --layout-features='*' --output-file=arabic.ttf
    pyftsubset /usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf --text="שָׁלוֹם עולם בְּרֵאשִׁית" --layout-features='*' --output-file=hebrew.ttf
    pyftsubset /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc --font-number=0 --text="日本語のテキストと中文汉字、한국어。" --layout-features='*' --output-file=cjk.otf

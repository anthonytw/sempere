/// Bump `current` whenever the bytes any exporter writes for the same note change (a renderer,
/// layout, font, outline or encoding change; the same moment the goldens or fixtures are
/// regenerated). Tree exports key each note's files on it, so a re-run after an upgrade renders
/// again instead of keeping files an older program wrote.
public enum RenderOutputVersion {
    public static let current = 2
}

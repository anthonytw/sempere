#if DEBUG
import Foundation
import Sempere

/// `SEMPERE_DEMO_INSIGHTS` (the Note Insights screenshots): recognized text for the demo's notes, so the fake
/// providers have words to summarize, compare and group. The demo's handwriting is not legible, so its pages carry
/// no text of their own; every sentence here is made up for the demo. Each note's first page gets the text as stored
/// recognition (`setPageRecognition`, no word boxes), written like the app's own recognizer's result.
extension DemoVault {
    /// The text of each note by `Spec.key`: biology, physics, team planning and travel, each with its own words, so the notes fall into
    /// distinct groups on the map and the tags and notebooks have summaries.
    static let insightsTexts: [String: String] = [
        "respiration": "Cellular respiration turns glucose into energy inside the mitochondria. Mitochondria use oxygen to make energy, and glucose is the fuel. The electron transport chain is the last stage of respiration.",
        "photosynthesis": "Photosynthesis turns sunlight into glucose inside the chloroplast. Chloroplast membranes hold chlorophyll, and glucose is the product. The Calvin cycle uses carbon dioxide and energy from the light reactions.",
        "quantum": "Quantum mechanics describes each particle with a wavefunction. Measurement of a quantum particle gives an eigenvalue, and the wavefunction collapses. Spin and momentum are quantum observables.",
        "optics": "Wave optics studies light as a wave. Diffraction and interference of light waves make fringes, and the wavelength sets the fringe spacing. A diffraction grating splits light by wavelength.",
        "sprint": "Sprint planning for the team: estimates, backlog and the release date. The team reviews the backlog before each sprint, and the sprint goal sets the release scope.",
        "weekly": "The weekly team meeting covers the sprint status, blockers and the release date. The team reviews the backlog and picks sprint tasks for the release.",
        "atlas": "A sketch of the sync design for the release: the team reviews the design, the backlog and the sprint tasks. Each device merges changes through a shared folder.",
        "lisbon": "The Lisbon itinerary for the trip: Alfama, the castle and Belem on the first days, then Sintra by train. The trip ends with the tram, the market and fado music in Lisbon.",
        "vocabulario": "Spanish vocabulary for the trip to Lisbon: the airport, the suitcase, the ticket and the train station. Practice the travel vocabulary before the trip.",
        "books": "A reading list of novels for the trip: a story of a journey, a garden and a library in Lisbon. Pack the novels for the long train journey.",
        "groceries": "The grocery list for the week: oat milk, tomatoes, coffee beans and basil. Buy tomatoes and basil at the market.",
        "thoughts": "A quick idea for the app: a keyboard shortcut for switching pens. The team can try the shortcut in the next sprint backlog.",
    ]

    /// The ops that give `spec`'s first page its recognized text, or none for a note without a text here.
    static func insightsOps(for spec: Spec) -> [Op] {
        guard let text = insightsTexts[spec.key] else { return [] }
        var rng = DemoRandom(seed: seed("page/" + spec.key))
        let page = rng.uuid()
        return [.setPageRecognition(pageId: page, recognition: Recognition(engine: "demo-1", text: text))]
    }
}
#endif

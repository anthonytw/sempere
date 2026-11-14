#if DEBUG
import Foundation
import Sempere

/// `SEMPERE_DEMO_INSIGHTS` (the Note Insights screenshots): recognized text for the demo's notes, so the fake
/// providers have words to summarize, compare and group. The demo's handwriting is not legible, so its pages carry
/// no text of their own; every sentence here is made up for the demo. Each note's first page gets the text as stored
/// recognition (`setPageRecognition`, no word boxes), written like the app's own recognizer's result.
extension DemoVault {
    /// The text of each note by `Spec.key`: science (biology and physics, linked by energy, electrons and light), a team's app project and a trip, each
    /// group with words of its own, so the notes fall into three clear groups on the map and the tags and notebooks have summaries.
    static let insightsTexts: [String: String] = [
        "respiration": "Cellular respiration turns glucose and oxygen into energy and carbon dioxide inside the mitochondria. The electron transport chain passes each electron along, and the energy it releases makes ATP. Photosynthesis runs this exchange of energy and oxygen the other way round. Energy, electrons and light tie biology to physics.",
        "photosynthesis": "Photosynthesis turns sunlight, carbon dioxide and water into glucose and oxygen inside the chloroplast. Light energy moves each electron along a chain, and the energy ends up stored in glucose. Respiration releases that energy again. Energy, electrons and light tie biology to physics.",
        "quantum": "Quantum mechanics describes each electron with a wavefunction. The energy of an electron comes in levels, and a measurement of the energy gives one eigenvalue. Light behaves as a wave and as a particle: a photon carries a quantum of energy. Energy, electrons and light tie biology to physics.",
        "optics": "Wave optics studies light as a wave. Diffraction and interference of light waves make fringes, and the wavelength sets the fringe spacing. A photon carries energy that depends on the wavelength of the light. Energy, electrons and light tie biology to physics.",
        "sprint": "Sprint planning for the team: estimates, backlog and the release date. The team reviews the backlog and the design before each sprint, and the sprint goal sets the release scope.",
        "weekly": "The weekly team meeting covers the sprint status, blockers and the release date. The team reviews the backlog, the design and the sprint tasks for the release.",
        "atlas": "A sketch of the sync design for the release: the team reviews the design, the backlog and the sprint tasks. Each device merges changes and the design keeps every device in step.",
        "thoughts": "A quick idea for the app design: a keyboard shortcut for switching pens. The team can add the shortcut to the sprint backlog and review the design before the release.",
        "lisbon": "The Lisbon itinerary for the trip: Alfama, the castle and Belem on the first days, then Sintra by train. The trip ends with the tram, the market and fado music in Lisbon.",
        "vocabulario": "Spanish vocabulary for the trip to Lisbon: the airport, the suitcase, the ticket and the train station. Practice the travel vocabulary before the trip.",
        "books": "A reading list of novels for the trip: a story of a journey, a garden and a library in Lisbon. Pack the novels for the long train journey.",
        "groceries": "The grocery list for the trip: coffee beans, oat milk, tomatoes and basil from the market in Lisbon. Buy the tomatoes and basil at the market the day before the trip.",
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

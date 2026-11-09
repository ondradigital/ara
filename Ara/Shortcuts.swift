import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation", initial: .init(.space, modifiers: [.option]))
    /// For apps whose text field cannot be read: select the corrected word and press this.
    static let learnSelection = Self("learnSelection", initial: .init(.space, modifiers: [.option, .shift]))
    /// Pastes the last transcript again, for when the first paste did not arrive.
    static let pasteLastTranscript = Self("pasteLastTranscript", initial: .init(.v, modifiers: [.control, .option]))
    static let cancelDictation = Self("cancelDictation", initial: .init(.escape))
}

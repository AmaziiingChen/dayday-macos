import Testing
@testable import DaydayApp

@Suite("Journal editor input synchronization")
struct JournalEditorInputSynchronizationTests {
  @Test("Tab structurally indents Markdown blocks instead of inserting literal spaces")
  func tabUsesMarkEditIndentCommand() {
    #expect(JournalMarkEditConfiguration.tabKeyBehavior == 3)
    #expect(JournalMarkEditConfiguration.indentUnit == "    ")
  }

  @Test("Pinyin marked text stays inside WebKit until composition ends")
  func compositionDefersNativeUpdates() {
    var state = JournalEditorInputSynchronizationState()

    let firstCandidate = state.viewDidUpdate(contentEdited: true, compositionEnded: false)
    let changedCandidate = state.viewDidUpdate(contentEdited: true, compositionEnded: false)

    #expect(firstCandidate.cancelsMarkdownSync)
    #expect(changedCandidate.cancelsMarkdownSync)
    #expect(!firstCandidate.publishesSelection)
    #expect(!firstCandidate.schedulesMarkdownSync)
    #expect(state.isComposing)

    let committed = state.compositionDidEnd()
    #expect(!state.isComposing)
    #expect(!committed.publishesSelection)
    #expect(committed.defersSelectionPublication)
    #expect(committed.notifiesUserEdit)
    #expect(committed.schedulesMarkdownSync)
  }

  @Test("Regular keyboard input keeps the debounced autosave path")
  func regularInputSynchronizesNormally() {
    var state = JournalEditorInputSynchronizationState()

    let decision = state.viewDidUpdate(contentEdited: true, compositionEnded: true)

    #expect(decision.publishesSelection)
    #expect(!decision.defersSelectionPublication)
    #expect(decision.notifiesUserEdit)
    #expect(!decision.cancelsMarkdownSync)
    #expect(decision.schedulesMarkdownSync)
    #expect(!state.isComposing)
  }

  @Test("A final CodeMirror update consumes the pending composition only once")
  func finalEditorUpdateConsumesPendingComposition() {
    var state = JournalEditorInputSynchronizationState()
    _ = state.viewDidUpdate(contentEdited: true, compositionEnded: false)

    let finalUpdate = state.viewDidUpdate(contentEdited: true, compositionEnded: true)
    let laterCompositionCallback = state.compositionDidEnd()

    #expect(finalUpdate.notifiesUserEdit)
    #expect(finalUpdate.schedulesMarkdownSync)
    #expect(!finalUpdate.publishesSelection)
    #expect(finalUpdate.defersSelectionPublication)
    #expect(!laterCompositionCallback.publishesSelection)
    #expect(laterCompositionCallback.defersSelectionPublication)
    #expect(!laterCompositionCallback.notifiesUserEdit)
    #expect(!laterCompositionCallback.schedulesMarkdownSync)
  }

  @Test("A CodeMirror update delivered after composition end still defers native selection")
  func compositionCallbackBeforeFinalEditorUpdate() {
    var state = JournalEditorInputSynchronizationState()
    _ = state.viewDidUpdate(contentEdited: true, compositionEnded: false)

    let compositionCallback = state.compositionDidEnd()
    let finalUpdate = state.viewDidUpdate(contentEdited: true, compositionEnded: true)

    #expect(compositionCallback.defersSelectionPublication)
    #expect(!finalUpdate.publishesSelection)
    #expect(finalUpdate.defersSelectionPublication)
    #expect(finalUpdate.notifiesUserEdit)
    #expect(finalUpdate.schedulesMarkdownSync)
  }

  @Test("Candidate navigation without a text edit defers selection after composition")
  func candidateNavigationDoesNotScheduleAutosave() {
    var state = JournalEditorInputSynchronizationState()

    let provisional = state.viewDidUpdate(contentEdited: false, compositionEnded: false)
    let committed = state.compositionDidEnd()

    #expect(provisional.cancelsMarkdownSync)
    #expect(!provisional.schedulesMarkdownSync)
    #expect(!committed.publishesSelection)
    #expect(committed.defersSelectionPublication)
    #expect(!committed.notifiesUserEdit)
    #expect(!committed.schedulesMarkdownSync)
  }

  @Test("A new Pinyin composition cancels the previous word's delayed checkpoint")
  func nextCompositionCancelsPreviousCheckpoint() {
    var state = JournalEditorInputSynchronizationState()

    let previousWord = state.viewDidUpdate(contentEdited: true, compositionEnded: true)
    let nextMarkedText = state.viewDidUpdate(contentEdited: true, compositionEnded: false)

    #expect(previousWord.schedulesMarkdownSync)
    #expect(!previousWord.cancelsMarkdownSync)
    #expect(nextMarkedText.cancelsMarkdownSync)
    #expect(!nextMarkedText.schedulesMarkdownSync)
  }
}

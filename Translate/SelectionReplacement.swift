import AppKit

/// The text element a selection came from: Accessibility in the app, an in-memory editor
/// in tests. Ranges are UTF-16, as Accessibility reports them.
protocol SelectionElement: AnyObject {
  var selectedText: String? { get }
  var selectedRange: NSRange? { get }
  var value: String? { get }
  /// Whether this is still the app's focused element. Another field in the same app may
  /// keep its old selection untouched, so range and value alone don't prove it's current.
  var isFocused: Bool { get }
}

/// One captured selection with everything needed to put a translation back exactly where
/// it was. Fixed at capture; a later capture never changes an earlier one.
struct CapturedSelection {
  enum Source {
    case accessibility
    case clipboard
  }

  static let maxCharacters = 16_000

  let text: String
  let source: Source
  let appPID: pid_t?
  let element: (any SelectionElement)?
  let range: NSRange?
  /// The element's whole value at capture, when the app exposes it.
  let value: String?

  /// What the element's value should read after replacing the captured range.
  func expectedValue(replacingWith replacement: String) -> String? {
    guard let value, let range else { return nil }
    return SelectedTextSplicer.splice(
      value: value,
      utf16Location: range.location,
      utf16Length: range.length,
      insertion: replacement
    )
  }

  /// Whether `element` still shows this selection: still focused, same range and value when
  /// the app exposes them, and the same selected text when it can be read.
  func isCurrent(in element: any SelectionElement) -> Bool {
    guard isAtCapturedPosition(in: element) else { return false }
    if range == nil, value == nil {
      return element.selectedText == text
    }
    if let selected = element.selectedText, selected != text { return false }
    return true
  }

  /// Focus, range and value only: what a clipboard capture can still check, since its
  /// text is only readable by copying again.
  func isAtCapturedPosition(in element: any SelectionElement) -> Bool {
    guard element.isFocused else { return false }
    if let range, element.selectedRange != range { return false }
    if let value, element.value != value { return false }
    return true
  }
}

enum CaptureResult {
  case selection(CapturedSelection)
  case empty
  /// Longer than `CapturedSelection.maxCharacters`; translating a clipped part and
  /// replacing the whole selection with it would lose text.
  case tooLong
}

enum ReplacementOutcome: Equatable {
  /// Read back exactly the expected text.
  case verified
  /// A paste was posted, but nothing could confirm the result.
  case unverified
  case failed(ReplacementFailure)
}

enum ReplacementFailure: Equatable {
  case appChanged
  case selectionChanged
  /// The paste was posted but the readable document is still exactly as captured.
  case notApplied
}

/// Puts a translation over a captured selection with one validated native paste. Mutates
/// only after checking the capture is still current, and never retries: Accessibility writes
/// can report success without changing anything, so a second mutation could duplicate text.
struct SelectionReplacer {
  var frontmostPID: () -> pid_t?
  var clipboard: ClipboardTransactions

  func replace(_ selection: CapturedSelection, with translation: String) async throws -> ReplacementOutcome {
    try Task.checkCancellation()
    guard isAppCurrent(selection) else { return .failed(.appChanged) }
    let element = selection.element
    let expected = selection.expectedValue(replacingWith: translation)

    let validation: PasteValidation
    if selection.source == .accessibility, let element {
      validation = .check { isAppCurrent(selection) && selection.isCurrent(in: element) }
    } else {
      // Equal text alone could be a repeat elsewhere, so whatever position the capture
      // recorded must match too, before and after copying again. With none, the text
      // comparison is the only check left.
      validation = .recopy(expected: selection.text, isAppCurrent: {
        isAppCurrent(selection) && (element.map(selection.isAtCapturedPosition(in:)) ?? true)
      })
    }
    let outcome = try await clipboard.paste(translation, validation: validation) {
      guard let element else { return false }
      return Self.readsBack(expected, in: element)
    }
    switch outcome {
    case .pasted(true):
      return .verified
    case .pasted(false):
      // Only a readable document that is provably as captured counts as a failure.
      let untouched = expected != nil && selection.value != nil && element?.value == selection.value
      return untouched ? .failed(.notApplied) : .unverified
    case .selectionChanged:
      return isAppCurrent(selection) ? .failed(.selectionChanged) : .failed(.appChanged)
    }
  }

  private func isAppCurrent(_ selection: CapturedSelection) -> Bool {
    guard let pid = selection.appPID else { return false }
    return frontmostPID() == pid
  }

  private static func readsBack(_ expected: String?, in element: any SelectionElement) -> Bool {
    guard let expected else { return false }
    return element.value == expected
  }
}

nonisolated enum SelectedTextSplicer {
  static func splice(
    value: String,
    utf16Location: Int,
    utf16Length: Int,
    insertion: String
  ) -> String? {
    let ns = value as NSString
    guard
      utf16Location >= 0,
      utf16Length >= 0,
      utf16Location <= ns.length,
      utf16Length <= ns.length - utf16Location
    else { return nil }
    return ns.replacingCharacters(
      in: NSRange(location: utf16Location, length: utf16Length),
      with: insertion
    )
  }
}

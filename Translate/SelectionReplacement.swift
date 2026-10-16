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
  /// True when the app accepted the write. Acceptance isn't proof it changed anything.
  func setSelectedText(_ text: String) -> Bool
  func setValue(_ value: String) -> Bool
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
  /// The app accepted a write or a paste was posted, but nothing could confirm the result.
  case unverified
  case failed(ReplacementFailure)
}

enum ReplacementFailure: Equatable {
  case appChanged
  case selectionChanged
}

/// Puts a translation over a captured selection. Mutates only after checking the capture
/// is still current, writes through Accessibility at most once per accepted write, and
/// falls back to a validated paste only when Accessibility refused without changing anything.
struct SelectionReplacer {
  var frontmostPID: () -> pid_t?
  var clipboard: ClipboardTransactions

  func replace(_ selection: CapturedSelection, with translation: String) async throws -> ReplacementOutcome {
    try Task.checkCancellation()
    guard isAppCurrent(selection) else { return .failed(.appChanged) }
    let expected = selection.expectedValue(replacingWith: translation)

    if selection.source == .accessibility, let element = selection.element {
      guard selection.isCurrent(in: element) else { return .failed(.selectionChanged) }
      if element.setSelectedText(translation) {
        return Self.readsBack(expected, in: element) ? .verified : .unverified
      }
      // Refused. Write again only if the element is provably untouched.
      guard selection.isCurrent(in: element) else { return .unverified }
      if let expected {
        if element.setValue(expected) {
          return element.value == expected ? .verified : .unverified
        }
        guard selection.isCurrent(in: element) else { return .unverified }
      }
    }

    let validation: PasteValidation
    if selection.source == .accessibility, let element = selection.element {
      validation = .check { isAppCurrent(selection) && selection.isCurrent(in: element) }
    } else {
      // Equal text alone could be a repeat elsewhere, so whatever position the capture
      // recorded must match too, before and after copying again. With none, the text
      // comparison is the only check left.
      let element = selection.element
      validation = .recopy(expected: selection.text, isAppCurrent: {
        isAppCurrent(selection) && (element.map(selection.isAtCapturedPosition(in:)) ?? true)
      })
    }
    let readBack = selection.element
    let outcome = try await clipboard.paste(translation, validation: validation) {
      guard let readBack else { return false }
      return Self.readsBack(expected, in: readBack)
    }
    switch outcome {
    case .pasted(let verified):
      return verified ? .verified : .unverified
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

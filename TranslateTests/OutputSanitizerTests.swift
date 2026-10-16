import Foundation
import Testing
@testable import Translate

struct OutputSanitizerTests {
  @Test func trimsWhitespace() {
    #expect(OutputSanitizer.sanitize("  hello  \n") == "hello")
  }

  @Test func stripsWrappingDoubleQuotes() {
    #expect(OutputSanitizer.sanitize("\"hello there\"") == "hello there")
  }

  @Test func stripsWrappingSmartQuotes() {
    #expect(OutputSanitizer.sanitize("“hello”") == "hello")
  }

  @Test func leavesInternalQuotesAlone() {
    #expect(OutputSanitizer.sanitize("He said \"hi\"") == "He said \"hi\"")
  }

  @Test func emptyStaysEmpty() {
    #expect(OutputSanitizer.sanitize("   ") == "")
  }

  @Test func stripsEchoedTextTags() {
    #expect(OutputSanitizer.sanitize("<text>\nLike Figma, but for docs.\n</text>") == "Like Figma, but for docs.")
    #expect(OutputSanitizer.sanitize("<text>\"hello\"</text>") == "hello")
  }
}

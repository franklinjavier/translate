import Foundation
import Testing
@testable import Translate

struct SelectedTextSplicerTests {
  @Test func replacesSelectedSpan() {
    #expect(
      SelectedTextSplicer.splice(
        value: "hello world",
        utf16Location: 6,
        utf16Length: 5,
        insertion: "there"
      ) == "hello there"
    )
  }

  @Test func rejectsOutOfRange() {
    #expect(
      SelectedTextSplicer.splice(
        value: "hi",
        utf16Location: 0,
        utf16Length: 8,
        insertion: "x"
      ) == nil
    )
  }

  @Test func rejectsInvalidAndOverflowingRanges() {
    let cases: [(Int, Int)] = [(1, Int.max), (Int.max, 1), (-1, 1), (0, -1), (NSNotFound, 0)]
    for (location, length) in cases {
      #expect(
        SelectedTextSplicer.splice(
          value: "abc",
          utf16Location: location,
          utf16Length: length,
          insertion: "x"
        ) == nil
      )
    }
  }
}

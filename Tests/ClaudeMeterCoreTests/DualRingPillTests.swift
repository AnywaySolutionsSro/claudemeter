@testable import ClaudeMeterCore
import Foundation
import Testing

struct DualRingPillTests {
    @Test func levelIsTheShareLeftClampedAndEmptyWithoutAReading() {
        #expect(DualRingPill.level(percentLeft: 68) == 0.68)
        #expect(DualRingPill.level(percentLeft: 140) == 1)
        #expect(DualRingPill.level(percentLeft: -5) == 0)
        #expect(DualRingPill.level(percentLeft: nil) == 0)
    }

    @Test func figuresAreRoundedPercentsOrADash() {
        #expect(DualRingPill.figure(percentLeft: 67.6) == "68%")
        #expect(DualRingPill.figure(percentLeft: nil) == "—")
    }

    @Test func textJoinsClaudeThenCodexAndMarksTheParts() {
        let text = DualRingPill.text(claudeLeft: 68, codexLeft: 96)
        #expect(text.string == "68% · 96%")
        #expect(text.claude == "68%")
        #expect(text.codex == "96%")
        #expect(text.separator == " · ")
        #expect(DualRingPill.text(claudeLeft: nil, codexLeft: 5).string == "— · 5%")
        #expect(DualRingPill.reference == "100% · 100%")
    }

    @Test func warningUnderTenPercentOnly() {
        #expect(DualRingPill.isWarning(percentLeft: 9.4))
        #expect(!DualRingPill.isWarning(percentLeft: 10))
        #expect(!DualRingPill.isWarning(percentLeft: nil))
    }

    @Test func ringsAreConcentricWithAGapBetweenThem() {
        let rings = DualRingPill.rings(width: 100, height: 22, lineWidth: 1.5, gap: 1, cornerRadius: 5)
        // Stroke centred half a line in from the edge.
        #expect(rings.outer == RingRect(x: 0.75, y: 0.75, width: 98.5, height: 20.5, radius: 5))
        // The inner stroke starts a line plus the gap further in: 1.5 + 1 + 0.75.
        #expect(rings.inner == RingRect(x: 3.25, y: 3.25, width: 93.5, height: 15.5, radius: 2.5))
        // Inner edge of the outer stroke to outer edge of the inner one is exactly the gap.
        #expect((rings.inner.x - 0.75) - (rings.outer.x + 0.75) == 1)
    }

    @Test func innerRadiusNeverGoesNegative() {
        let rings = DualRingPill.rings(width: 40, height: 18, lineWidth: 2, gap: 1, cornerRadius: 2)
        #expect(rings.inner.radius == 0)
    }

    @Test func bandIsWhatTheRingsTakeFromEachSide() {
        #expect(DualRingPill.band(lineWidth: 1.5, gap: 1) == 4)
    }

    @Test func perimeterOfARoundedRect() {
        // A circle-ended rect: straight sides plus one full circle.
        let rect = RingRect(x: 0, y: 0, width: 20, height: 10, radius: 5)
        #expect(abs(rect.perimeter - (2 * 10 + 2 * 0 + 2 * Double.pi * 5)) < 1e-9)
    }
}

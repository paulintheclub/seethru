import Testing
@testable import SeethruCore

@Suite struct OpacityStepperTests {
    @Test func stepsByTenPercent() {
        #expect(OpacityStepper.step(1.0, .moreTransparent) == 0.9)
        #expect(OpacityStepper.step(0.5, .moreOpaque) == 0.6)
    }

    @Test func clampsAtBounds() {
        #expect(OpacityStepper.step(0.1, .moreTransparent) == 0.1)
        #expect(OpacityStepper.step(1.0, .moreOpaque) == 1.0)
    }

    @Test func doesNotDriftOverManySteps() {
        var v = 1.0
        for _ in 0..<7 { v = OpacityStepper.step(v, .moreTransparent) }
        #expect(v == 0.3)
        for _ in 0..<7 { v = OpacityStepper.step(v, .moreOpaque) }
        #expect(v == 1.0)
    }

    @Test func peekCapsButNeverRaises() {
        #expect(OpacityStepper.effective(0.8, peek: true) == 0.2)
        #expect(OpacityStepper.effective(0.1, peek: true) == 0.1)
        #expect(OpacityStepper.effective(0.8, peek: false) == 0.8)
    }
}

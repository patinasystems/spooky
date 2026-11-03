import AppKit
import Testing
@testable import Ghostty

@MainActor
struct SurfaceScrollerTrackTests {
    @Test func footerInsetsMoveActualTrackAndKnobWithoutChangingContentGeometry() throws {
        let scrollView = makeScrollView()
        let scroller = try #require(scrollView.verticalScroller)
        let originalTrack = scroller.frame
        let contentSize = scrollView.contentSize
        let contentFrame = scrollView.contentView.frame
        let contentBounds = scrollView.contentView.bounds
        let documentFrame = try #require(scrollView.documentView).frame
        // NSScrollView is flipped on current macOS: its visual bottom is at
        // maxY. Derive the footer from that actual coordinate system.
        // A 44pt editor plus two18pt caption rows occupy the bottom80pt.
        let footerHeight: CGFloat = 80
        let footerY = scrollView.isFlipped ? scrollView.bounds.maxY - footerHeight : scrollView.bounds.minY
        let footer = NSRect(x: 0, y: footerY, width: 400, height: footerHeight)

        #expect(SurfaceScrollerTrack.applyBottomInset(footer.height, to: scrollView))
        #expect(scroller.frame.height > 0)
        #expect(scroller.frame.height == originalTrack.height - footerHeight)
        if scrollView.isFlipped {
            #expect(scroller.frame.maxY <= footer.minY)
            #expect(scroller.frame.minY == originalTrack.minY)
        } else {
            #expect(scroller.frame.minY >= footer.maxY)
            #expect(scroller.frame.maxY == originalTrack.maxY)
        }
        #expect(!scroller.frame.intersects(footer))
        for position in [0.0, 1.0] {
            scroller.doubleValue = position
            let knob = scrollView.convert(scroller.rect(for: .knob), from: scroller)
            #expect(knob.height > 0)
            #expect(!knob.intersects(footer))
        }
        #expect(scrollView.contentSize == contentSize)
        #expect(scrollView.contentView.frame == contentFrame)
        #expect(scrollView.contentView.bounds == contentBounds)
        #expect(scrollView.documentView?.frame == documentFrame)

        #expect(SurfaceScrollerTrack.applyBottomInset(0, to: scrollView))
        #expect(scroller.frame == originalTrack)
        #expect(scrollView.contentSize == contentSize)
    }

    @Test func unchangedInsetSkipsTilingAndPreservesOtherInsets() {
        let scrollView = makeScrollView()
        scrollView.scrollerInsets = NSEdgeInsets(top: 3, left: 2, bottom: 0, right: 1)
        #expect(SurfaceScrollerTrack.applyBottomInset(80, to: scrollView))
        let calls = scrollView.tileCalls
        #expect(!SurfaceScrollerTrack.applyBottomInset(80, to: scrollView))
        #expect(scrollView.tileCalls == calls)
        #expect(scrollView.scrollerInsets.top == 3)
        #expect(scrollView.scrollerInsets.left == 2)
        #expect(scrollView.scrollerInsets.right == 1)
    }

    private func makeScrollView() -> CountingScrollView {
        let scrollView = CountingScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = false
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 4_000))
        scrollView.tile()
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return scrollView
    }

    private final class CountingScrollView: NSScrollView {
        var tileCalls = 0
        override func tile() {
            tileCalls += 1
            super.tile()
        }
    }
}

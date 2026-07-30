import AppKit
import QuartzCore

@main
struct TimelineSuggestionGeometrySmoke {
    static func main() {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 126)
        let timeline = TimelineSuggestionLayout.timelineRect(in: bounds, laneCount: 2)
        let firstLane = TimelineSuggestionLayout.annotationFrame(
            timelineRect: timeline,
            lane: 0,
            startX: 100,
            endX: 400
        )
        let secondLane = TimelineSuggestionLayout.annotationFrame(
            timelineRect: timeline,
            lane: 1,
            startX: 200,
            endX: 500
        )

        precondition(
            firstLane.minY > timeline.maxY,
            "Suggestions must render below timeline content in surface coordinates."
        )
        precondition(
            secondLane.minY > firstLane.maxY,
            "Overlapping suggestions must occupy distinct visual lanes."
        )
        precondition(
            secondLane.maxY < bounds.maxY,
            "Suggestion lanes must remain within the timeline surface."
        )

        let hitRect = TimelineSuggestionLayout.hitRect(for: firstLane)
        precondition(hitRect.contains(firstLane.center))
        precondition(
            hitRect.minY > timeline.maxY,
            "Suggestion hit targets must not overlap timeline scrubbing content."
        )

        let hostView = NSView(frame: bounds)
        hostView.wantsLayer = true
        let rootLayer = hostView.layer!
        let surfaceLayer = CALayer()
        surfaceLayer.frame = bounds
        surfaceLayer.isGeometryFlipped = true
        rootLayer.addSublayer(surfaceLayer)
        let suggestionLayer = CALayer()
        suggestionLayer.frame = bounds
        surfaceLayer.addSublayer(suggestionLayer)

        let rootTimeline = surfaceLayer.convert(timeline, to: rootLayer)
        let rootAnnotation = suggestionLayer.convert(firstLane, to: rootLayer)
        let rootHitRect = suggestionLayer.convert(hitRect, to: rootLayer)
        precondition(
            rootAnnotation.maxY < rootTimeline.minY,
            "Layer conversion must keep suggestions visually below timeline content."
        )
        precondition(
            rootHitRect.maxY < rootTimeline.minY,
            "Converted suggestion hit targets must not overlap timeline scrubbing."
        )

        let pointAnnotation = TimelineSuggestionLayout.annotationFrame(
            timelineRect: timeline,
            lane: 0,
            startX: 600
        )
        let headSize: CGFloat = 8
        let headOriginY =
            pointAnnotation.minY +
            ((TimelineSuggestionLayout.annotationHeight - headSize) / 2)
        let pinTopY = timeline.minY - 2
        let headLocalY = headOriginY - pinTopY
        let pointPin = CALayer()
        pointPin.frame = CGRect(
            x: pointAnnotation.midX - (headSize / 2),
            y: pinTopY,
            width: headSize,
            height: headLocalY + headSize
        )
        suggestionLayer.addSublayer(pointPin)
        precondition(
            pointPin.isGeometryFlipped == false,
            "Suggestion pins must use the established surface coordinate system without another flip."
        )
        let pointHeadInSurface = pointPin.convert(
            CGRect(x: 0, y: headLocalY, width: headSize, height: headSize),
            to: surfaceLayer
        )
        precondition(
            pointHeadInSurface.minY > timeline.maxY,
            "Suggestion pin heads must render below timeline content."
        )

        let firstID = UUID()
        let overlappingID = UUID()
        let laterID = UUID()
        let lanes = TimelineSuggestionLayout.laneAssignments(
            for: [
                TimelineSuggestionInterval(
                    id: firstID,
                    startSeconds: 10,
                    endSeconds: 30
                ),
                TimelineSuggestionInterval(
                    id: overlappingID,
                    startSeconds: 20,
                    endSeconds: 25
                ),
                TimelineSuggestionInterval(
                    id: laterID,
                    startSeconds: 31,
                    endSeconds: 40
                )
            ]
        )
        precondition(lanes[firstID] == 0)
        precondition(lanes[overlappingID] == 1)
        precondition(lanes[laterID] == 0)

        print("Timeline suggestion geometry smoke test passed.")
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

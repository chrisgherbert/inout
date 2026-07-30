import Foundation
import CoreGraphics

struct TimelineSuggestionInterval: Equatable {
    let id: UUID
    let startSeconds: Double
    let endSeconds: Double
}

enum TimelineSuggestionLayout {
    static let rulerHeight: CGFloat = 16
    static let rulerGap: CGFloat = 2
    static let timelineTopGutter: CGFloat = 8
    static let timelineBottomGutter: CGFloat = 8
    static let lanePitch: CGFloat = 19
    static let annotationHeight: CGFloat = 17
    static let annotationGap: CGFloat = 3

    static func timelineRect(in bounds: CGRect, laneCount: Int) -> CGRect {
        let laneGutter = CGFloat(max(0, laneCount)) * lanePitch
        let originY = rulerHeight + rulerGap + timelineTopGutter
        let availableHeight =
            bounds.height - originY - timelineBottomGutter - laneGutter
        let height = max(CGFloat(1), availableHeight)
        return CGRect(
            x: bounds.minX,
            y: bounds.minY + originY,
            width: bounds.width,
            height: height
        )
    }

    static func annotationFrame(
        timelineRect: CGRect,
        lane: Int,
        startX: CGFloat,
        endX: CGFloat? = nil
    ) -> CGRect {
        let resolvedEndX = endX ?? startX
        let laneOffset = CGFloat(max(0, lane)) * lanePitch
        let originX = min(startX, resolvedEndX) - 5
        let originY = timelineRect.maxY + annotationGap + laneOffset
        let width = max(CGFloat(10), abs(resolvedEndX - startX) + 10)
        return CGRect(
            x: originX,
            y: originY,
            width: width,
            height: annotationHeight
        )
    }

    static func hitRect(for annotationFrame: CGRect) -> CGRect {
        annotationFrame.insetBy(dx: -3, dy: -2)
    }

    static func laneAssignments(
        for intervals: [TimelineSuggestionInterval]
    ) -> [UUID: Int] {
        let sorted = intervals.sorted {
            if abs($0.startSeconds - $1.startSeconds) > 0.0001 {
                return $0.startSeconds < $1.startSeconds
            }
            return $0.endSeconds < $1.endSeconds
        }
        var laneEndSeconds: [Double] = []
        var laneByID: [UUID: Int] = [:]
        for interval in sorted {
            let lane = laneEndSeconds.firstIndex {
                $0 <= interval.startSeconds + 0.0001
            } ?? laneEndSeconds.count
            if lane == laneEndSeconds.count {
                laneEndSeconds.append(interval.endSeconds)
            } else {
                laneEndSeconds[lane] = interval.endSeconds
            }
            laneByID[interval.id] = lane
        }
        return laneByID
    }
}

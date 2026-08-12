import AVFoundation

enum FastExportUtilities {
    private static let selectionTimescale: CMTimeScale = 600_000
    private static let maximumSyncSearchSamples = 20_000

    static func exportTimeRange(
        for asset: AVURLAsset,
        selectedStartSeconds: Double,
        selectedEndSeconds: Double
    ) async -> CMTimeRange {
        let requestedStart = preciseTime(seconds: selectedStartSeconds)
        let requestedEnd = preciseTime(seconds: selectedEndSeconds)
        let requestedRange = CMTimeRange(start: requestedStart, end: requestedEnd)

        guard CMTimeCompare(requestedEnd, requestedStart) > 0,
              let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let canProvideSampleCursors = try? await videoTrack.load(.canProvideSampleCursors),
              canProvideSampleCursors,
              let trackTimeRange = try? await videoTrack.load(.timeRange),
              let segments = try? await videoTrack.load(.segments) else {
            return requestedRange
        }

        let safeStart = precedingFullSyncSampleStart(
            at: requestedStart,
            track: videoTrack,
            trackTimeRange: trackTimeRange,
            segments: segments
        )
        let safeEnd = videoSampleEnd(
            containing: requestedEnd,
            track: videoTrack,
            segments: segments
        )
        let expandedStart = minTime(requestedStart, safeStart ?? requestedStart)
        let expandedEnd = maxTime(requestedEnd, safeEnd ?? requestedEnd)
        guard CMTimeCompare(expandedEnd, expandedStart) > 0 else {
            return requestedRange
        }
        return CMTimeRange(start: expandedStart, end: expandedEnd)
    }

    private static func preciseTime(seconds: Double) -> CMTime {
        guard seconds.isFinite else { return .zero }
        let value = Int64((max(0, seconds) * Double(selectionTimescale)).rounded())
        return CMTime(value: value, timescale: selectionTimescale)
    }

    private static func precedingFullSyncSampleStart(
        at target: CMTime,
        track: AVAssetTrack,
        trackTimeRange: CMTimeRange,
        segments: [AVAssetTrackSegment]
    ) -> CMTime? {
        guard CMTimeCompare(target, trackTimeRange.start) > 0,
              let sourceTarget = sourceTime(for: target, segments: segments),
              let cursor = track.makeSampleCursor(presentationTimeStamp: sourceTarget) else {
            return trackTimeRange.start
        }

        for _ in 0..<maximumSyncSearchSamples {
            let sourceSampleStart = cursor.presentationTimeStamp
            if CMTIME_IS_NUMERIC(sourceSampleStart),
               CMTimeCompare(sourceSampleStart, sourceTarget) <= 0,
               cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                return targetTime(for: sourceSampleStart, segments: segments)
            }
            guard cursor.stepInPresentationOrder(byCount: -1) != 0 else {
                break
            }
        }

        // Starting from the track boundary is safer than risking a late start
        // when a format does not expose full-sync sample metadata reliably.
        return trackTimeRange.start
    }

    private static func videoSampleEnd(
        containing target: CMTime,
        track: AVAssetTrack,
        segments: [AVAssetTrackSegment]
    ) -> CMTime? {
        guard let sourceTarget = sourceTime(for: target, segments: segments),
              let cursor = track.makeSampleCursor(presentationTimeStamp: sourceTarget) else {
            return nil
        }

        for _ in 0..<64 {
            let sourceSampleStart = cursor.presentationTimeStamp
            let sampleDuration = cursor.currentSampleDuration
            if CMTIME_IS_NUMERIC(sourceSampleStart), CMTIME_IS_NUMERIC(sampleDuration) {
                let sourceSampleEnd = CMTimeAdd(sourceSampleStart, sampleDuration)
                if CMTimeCompare(sourceSampleStart, sourceTarget) <= 0,
                   CMTimeCompare(sourceTarget, sourceSampleEnd) < 0 {
                    return targetTime(for: sourceSampleEnd, segments: segments)
                }
            }

            let direction: Int64 = CMTimeCompare(sourceSampleStart, sourceTarget) > 0 ? -1 : 1
            guard cursor.stepInPresentationOrder(byCount: direction) != 0 else {
                break
            }
        }
        return nil
    }

    private static func sourceTime(
        for targetTime: CMTime,
        segments: [AVAssetTrackSegment]
    ) -> CMTime? {
        guard let segment = segments.first(where: {
            !$0.isEmpty && time($0.timeMapping.target, contains: targetTime)
        }) else { return nil }
        return CMTimeMapTimeFromRangeToRange(
            targetTime,
            fromRange: segment.timeMapping.target,
            toRange: segment.timeMapping.source
        )
    }

    private static func targetTime(
        for sourceTime: CMTime,
        segments: [AVAssetTrackSegment]
    ) -> CMTime? {
        guard let segment = segments.first(where: {
            !$0.isEmpty && time($0.timeMapping.source, contains: sourceTime)
        }) else { return nil }
        return CMTimeMapTimeFromRangeToRange(
            sourceTime,
            fromRange: segment.timeMapping.source,
            toRange: segment.timeMapping.target
        )
    }

    private static func time(_ range: CMTimeRange, contains candidate: CMTime) -> Bool {
        CMTimeCompare(candidate, range.start) >= 0 &&
            CMTimeCompare(candidate, range.end) <= 0
    }

    private static func minTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeCompare(lhs, rhs) <= 0 ? lhs : rhs
    }

    private static func maxTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeCompare(lhs, rhs) >= 0 ? lhs : rhs
    }
}

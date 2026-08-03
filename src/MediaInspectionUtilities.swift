import AVFoundation

func mediaContentTimeRange(for track: AVAssetTrack) -> (start: Double, duration: Double)? {
    let populatedRanges = track.segments
        .filter { !$0.isEmpty }
        .map(\.timeMapping.target)

    if let firstStart = populatedRanges.map(\.start).min(),
       let lastEnd = populatedRanges.map(\.end).max() {
        let start = CMTimeGetSeconds(firstStart)
        let end = CMTimeGetSeconds(lastEnd)
        if start.isFinite, end.isFinite, end > start {
            return (start, end - start)
        }
    }

    let start = CMTimeGetSeconds(track.timeRange.start)
    let duration = CMTimeGetSeconds(track.timeRange.duration)
    guard start.isFinite, duration.isFinite, duration > 0 else { return nil }
    return (start, duration)
}

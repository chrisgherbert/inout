import AVFoundation
import Foundation

@main
struct InspectMediaInfoSmoke {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Expected a media path")
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              let audioTrack = asset.tracks(withMediaType: .audio).first,
              let video = mediaContentTimeRange(for: videoTrack),
              let audio = mediaContentTimeRange(for: audioTrack) else {
            fatalError("Expected readable audio and video timing")
        }

        let videoEnd = video.start + video.duration
        let audioEnd = audio.start + audio.duration
        let maximumOffset = max(abs(audio.start - video.start), abs(audioEnd - videoEnd))

        precondition(abs(video.start) < 0.01, "Video should begin at zero")
        precondition(audio.start >= 0.2, "Empty edit-list padding must not hide the delayed audio start")
        precondition(maximumOffset >= 0.2, "The timing discrepancy should be detected")

        print(String(
            format: "Inspect media info smoke passed: video %.3f-%.3f, audio %.3f-%.3f, max offset %.3fs",
            video.start,
            videoEnd,
            audio.start,
            audioEnd,
            maximumOffset
        ))
    }
}

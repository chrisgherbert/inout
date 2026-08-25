import Combine
import Foundation

final class WorkspaceViewModel: ObservableObject {}

@main
struct VideoExportEncodingSmoke {
    static func main() {
        requirePlan(
            format: .mp4,
            codec: .h264,
            speed: .fast,
            pass: .final,
            encoder: "h264_videotoolbox",
            options: ["-prio_speed", "true"]
        )
        requirePlan(
            format: .mov,
            codec: .hevc,
            speed: .fast,
            pass: .final,
            encoder: "hevc_videotoolbox",
            options: ["-prio_speed", "true"]
        )
        requirePlan(
            format: .mp4,
            codec: .h264,
            speed: .balanced,
            pass: .final,
            encoder: "libx264",
            options: ["-preset", "veryfast"]
        )
        requirePlan(
            format: .mkv,
            codec: .hevc,
            speed: .balanced,
            pass: .final,
            encoder: "libx265",
            options: ["-preset", "faster"]
        )
        requirePlan(
            format: .mp4,
            codec: .h264,
            speed: .quality,
            pass: .final,
            encoder: "libx264",
            options: ["-preset", "medium"]
        )
        requirePlan(
            format: .mov,
            codec: .hevc,
            speed: .quality,
            pass: .final,
            encoder: "libx265",
            options: ["-preset", "medium"]
        )

        requirePlan(
            format: .webm,
            codec: .h264,
            speed: .fast,
            pass: .final,
            encoder: "libvpx-vp9",
            options: ["-deadline", "realtime", "-cpu-used", "7", "-row-mt", "1"]
        )
        requirePlan(
            format: .webm,
            codec: .h264,
            speed: .balanced,
            pass: .final,
            encoder: "libvpx-vp9",
            options: ["-deadline", "good", "-cpu-used", "5", "-row-mt", "1"]
        )
        requirePlan(
            format: .webm,
            codec: .h264,
            speed: .quality,
            pass: .final,
            encoder: "libvpx-vp9",
            options: ["-deadline", "good", "-cpu-used", "2", "-row-mt", "1"]
        )

        requirePlan(
            format: .mp4,
            codec: .h264,
            speed: .quality,
            pass: .captionStage,
            encoder: "h264_videotoolbox",
            options: []
        )
        requirePlan(
            format: .mov,
            codec: .hevc,
            speed: .quality,
            pass: .captionStage,
            encoder: "hevc_videotoolbox",
            options: []
        )
        requirePlan(
            format: .webm,
            codec: .h264,
            speed: .quality,
            pass: .captionStage,
            encoder: "h264_videotoolbox",
            options: []
        )

        print("Video export encoding policy smoke test passed.")
    }

    private static func requirePlan(
        format: ClipFormat,
        codec: AdvancedVideoCodec,
        speed: CompatibleSpeedPreset,
        pass: VideoExportEncodingPass,
        encoder: String,
        options: [String]
    ) {
        let plan = videoExportEncodingPlan(
            format: format,
            codec: codec,
            speed: speed,
            pass: pass
        )
        guard plan == VideoExportEncodingPlan(encoder: encoder, options: options) else {
            fputs(
                "Unexpected plan for \(format.rawValue), \(codec.rawValue), \(speed.rawValue), \(pass): \(plan)\n",
                stderr
            )
            exit(1)
        }
        guard !plan.options.contains("-preset") || plan.encoder == "libx264" || plan.encoder == "libx265" else {
            fputs("Unsupported -preset option applied to \(plan.encoder).\n", stderr)
            exit(1)
        }
        guard !plan.options.contains("-realtime") else {
            fputs("VideoToolbox real-time mode throttles file exports.\n", stderr)
            exit(1)
        }
    }
}

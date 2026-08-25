enum VideoExportEncodingPass {
    case final
    case captionStage
}

struct VideoExportEncodingPlan: Equatable {
    let encoder: String
    let options: [String]
}

func videoExportEncodingPlan(
    format: ClipFormat,
    codec: AdvancedVideoCodec,
    speed: CompatibleSpeedPreset,
    pass: VideoExportEncodingPass
) -> VideoExportEncodingPlan {
    if pass == .captionStage {
        // WebM cannot contain H.264, so its hardware-encoded staging clip uses
        // Matroska internally before the final VP9 pass.
        let encoder = format == .webm
            ? "h264_videotoolbox"
            : (codec == .hevc ? "hevc_videotoolbox" : "h264_videotoolbox")
        return VideoExportEncodingPlan(
            encoder: encoder,
            options: []
        )
    }

    if format == .webm {
        let options: [String]
        switch speed {
        case .fast:
            options = ["-deadline", "realtime", "-cpu-used", "7", "-row-mt", "1"]
        case .balanced:
            options = ["-deadline", "good", "-cpu-used", "5", "-row-mt", "1"]
        case .quality:
            options = ["-deadline", "good", "-cpu-used", "2", "-row-mt", "1"]
        }
        return VideoExportEncodingPlan(encoder: "libvpx-vp9", options: options)
    }

    if speed == .fast {
        let encoder = codec == .hevc ? "hevc_videotoolbox" : "h264_videotoolbox"
        return VideoExportEncodingPlan(
            encoder: encoder,
            options: ["-prio_speed", "true"]
        )
    }

    let encoder = codec == .hevc ? "libx265" : "libx264"
    let preset: String
    switch speed {
    case .fast:
        preconditionFailure("Fast exports use VideoToolbox.")
    case .balanced:
        preset = codec == .hevc ? "faster" : "veryfast"
    case .quality:
        preset = "medium"
    }
    return VideoExportEncodingPlan(encoder: encoder, options: ["-preset", preset])
}

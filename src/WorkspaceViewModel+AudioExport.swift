import Foundation

extension WorkspaceViewModel {
    func stopExport() {
        guard isExporting else { return }
        let queueJobID = activeQueuedJobID
        exportCancellationRequested = true
        exportCancelFlag.cancel()
        activeClipExportRunToken = nil
        activeExportSession?.cancelExport()
        if let process = activeProcess, process.isRunning {
            process.terminate()
        }
        exportTask?.cancel()
        exportTask = nil
        activeExportSession = nil
        activeProcess = nil
        isExporting = false
        exportProgress = 0
        exportStatusText = "Export cancelled"
        uiMessage = exportStatusText
        lastActivityState = .cancelled
        completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: "Stopped by user.")
    }
}

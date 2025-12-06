import Foundation
import AVFoundation

class AudioRecorder: NSObject, ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    @Published var isRecording = false
    
    func startRecording() -> URL? {
        // Request permission explicitly first
        if #available(macOS 10.14, *) {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                break // Already authorized
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    if !granted { print("❌ [AudioRecorder] Permission denied by user") }
                }
            case .denied, .restricted:
                print("❌ [AudioRecorder] Permission denied or restricted")
                return nil
            @unknown default:
                return nil
            }
        }

        // Define file path
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("clippy_voice_command.m4a")
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            guard audioRecorder?.prepareToRecord() == true else {
                print("❌ [AudioRecorder] Failed to prepare recording")
                return nil
            }
            
            // Ensure we are on main thread if needed, though record() is thread-safe usually
            if audioRecorder?.record() == true {
                isRecording = true
                print("🎙️ [AudioRecorder] Started recording to \(fileURL.path)")
                return fileURL
            } else {
                print("❌ [AudioRecorder] record() returned false")
                return nil
            }
        } catch {
            print("❌ [AudioRecorder] Failed to start recording: \(error)")
            return nil
        }
    }
    
    func stopRecording() -> URL? {
        guard let recorder = audioRecorder, isRecording else { 
            print("⚠️ [AudioRecorder] stopRecording called but not recording")
            return nil 
        }
        
        recorder.stop()
        isRecording = false
        let url = recorder.url
        
        // Verify file was created and has content
        let path = url.path
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        print("🛑 [AudioRecorder] Stopped recording. File size: \(fileSize) bytes at \(path)")
        
        return url
    }
}


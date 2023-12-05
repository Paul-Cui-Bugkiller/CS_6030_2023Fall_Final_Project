import Foundation
import AVFoundation
import Combine
import Accelerate
import SwiftUI

@MainActor
final class AudioAnalyzer: ObservableObject {
    private var audioEngine = AVAudioEngine()
    private let fftSetup: FFTSetup
    private let fftLength: vDSP_Length
    private var fftNormFactor: Float32
    private var audioPlayerNode: AVAudioPlayerNode?
    private var sessionExists: Bool = false
    @Published var isPlaying: Bool = false
    private var fileSampleRate: Double = 0
    let bufferSize = 1024

    init() {
        fftLength = vDSP_Length(log2f(Float(bufferSize)))
        fftNormFactor = 1.0 / Float(2 * bufferSize)
        fftSetup = vDSP_create_fftsetup(fftLength, FFTRadix(kFFTRadix2))!
    }

    func start(url: URL, completion: @escaping @Sendable ([Float])->Void) {
        if(self.sessionExists){
            self.audioEngine.prepare()
            try! self.audioEngine.start()
            if(self.audioPlayerNode != nil){
                self.audioPlayerNode!.play()
                self.isPlaying = true
            }
            else{
                self.audioEngine.stop()
            }
        }
        else{
            let audioSession = sharedAVAudioSession
            print("device sample Rate: \(audioSession.sampleRate)")

            self.audioPlayerNode = AVAudioPlayerNode()

            self.audioEngine.attach(self.audioPlayerNode!)
//            
            let file = try! AVAudioFile(forReading: url)

            self.fileSampleRate = file.processingFormat.sampleRate
            print("fileFormat sampleRate: \(file.fileFormat.sampleRate)")
            print("processingFormat sampleRate: \(file.processingFormat.sampleRate)")
            
            if(file.processingFormat.sampleRate == 48000.0){
                let speedControl = AVAudioUnitVarispeed()
                speedControl.rate = Float(self.fileSampleRate / 44100.0)    // weird workaround for 48KHz files for iOS
                self.audioEngine.attach(speedControl)
                self.audioEngine.connect(self.audioPlayerNode!, to: speedControl, format: nil)
                self.audioEngine.connect(speedControl, to: self.audioEngine.mainMixerNode, format: file.processingFormat)
            }
            else{
                self.audioEngine.connect(self.audioPlayerNode!, to: self.audioEngine.mainMixerNode, format: file.processingFormat)
            }
            
            self.audioPlayerNode!.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack){
                _ in
                DispatchQueue.main.async{
                    completion([0,0,0,0,0,0,0,0,0,0])
                    self.stop()
                }
            }
            
            // Define the FFT setup
            let fftSize = 1024 // Ensure this is a power of 2
            let log2n = UInt(log2(Float(fftSize)))
            let bufferSize = Int(fftSize / 2)

            var realp = [Float](repeating: 0, count: bufferSize)
            var imagp = [Float](repeating: 0, count: bufferSize)
            var fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

            // Install tap on mixer node
            self.audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: nil) { (buffer, when) in
                // Convert buffer to array
                guard let channelData = buffer.floatChannelData else { return }
                var array = [Float](UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))

                // Perform FFT
                array.withUnsafeMutableBytes { ptr in
                    let ptr = ptr.bindMemory(to: DSPComplex.self)
                    let floatPtr = UnsafeMutablePointer(mutating: ptr.baseAddress!)
                    let splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)

                    vDSP_ctoz(floatPtr, 2, &splitComplex, 1, vDSP_Length(bufferSize))

                    vDSP_fft_zrip(fftSetup!, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                }

                // Compute magnitudes
                var magnitudes = [Float](repeating: 0.0, count: bufferSize)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(bufferSize))

                // Normalize magnitudes
                var normalizedMagnitudes = [Float](repeating: 0.0, count: bufferSize)
                vDSP_vsmul(sqrtf(magnitudes), 1, [2.0 / Float(fftSize)], &normalizedMagnitudes, 1, vDSP_Length(bufferSize))

                // competion
            }
            
            self.audioEngine.prepare()
            try! self.audioEngine.start()

            self.audioPlayerNode!.play()
            self.isPlaying = true
            self.sessionExists = true
        }
    }
    
    func stop(){
        if(self.audioPlayerNode != nil){
            if(self.audioPlayerNode!.isPlaying){
                self.audioPlayerNode!.stop()
            }
        }
        self.audioEngine.stop()
        self.isPlaying = false
        self.sessionExists = false
        self.audioEngine = AVAudioEngine()
        self.audioPlayerNode = nil
    }
    
    func pause(){
        if(self.audioPlayerNode != nil){
            self.audioPlayerNode!.pause()
        }
        self.audioEngine.pause()
        self.isPlaying = false
    }
}
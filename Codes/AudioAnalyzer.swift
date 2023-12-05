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

            self.audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(bufferSize), format: file.processingFormat) {
                [self] (buffer, time) in
                guard let channelData = buffer.floatChannelData?[0] else { return }

                var fftMagnitudes = [Float](repeating: 0.0, count: Int(bufferSize / 2))
                var realp = [Float](repeating: 0.0, count: Int(bufferSize / 2))
                var imagp = [Float](repeating: 0.0, count: Int(bufferSize / 2))
                realp.withUnsafeMutableBufferPointer{
                    realBP in
                    imagp.withUnsafeMutableBufferPointer{
                        imagBP in
                        var dspSplitComplex = DSPSplitComplex(realp: realBP.baseAddress!, imagp: imagBP.baseAddress!)
                        channelData.withMemoryRebound(to: DSPComplex.self, capacity: Int(bufferSize)) {
                            vDSP_ctoz($0, 2, &dspSplitComplex, 1, vDSP_Length(bufferSize / 2))
                        }

                        vDSP_fft_zrip(self.fftSetup, &dspSplitComplex, 1, self.fftLength, FFTDirection(kFFTDirection_Forward))

                        vDSP_zvmags(&dspSplitComplex, 1, &fftMagnitudes, 1, vDSP_Length(bufferSize / 2))

//                        var dbPower = [Float](repeating: 0.0, count: Int(bufferSize / 2))
////                        vDSP_vdbcon(&fftMagnitudes, 1, &fftNormFactor, &dbPower, 1, vDSP_Length(bufferSize / 2), 0)
//                        vDSP_zvmags(&dspSplitComplex, 1, &dbPower, 1, vDSP_Length(bufferSize/2))

                        let hzPerBin =  self.fileSampleRate / Double(bufferSize)
                        // 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k
//                        let binIndexs = [Int(20 / hzPerBin), Int(1795 / hzPerBin), Int(3570 / hzPerBin), Int(5345 / hzPerBin), Int(7120 / hzPerBin), Int(8895 / hzPerBin), Int(10670 / hzPerBin), Int(12445 / hzPerBin), Int(14220 / hzPerBin), Int(16000 / hzPerBin)]
                        let binIndexs = [Int(31 / hzPerBin), Int(62 / hzPerBin), Int(125 / hzPerBin), Int(250 / hzPerBin), Int(500 / hzPerBin), Int(1000 / hzPerBin), Int(2000 / hzPerBin), Int(4000 / hzPerBin), Int(8000 / hzPerBin), Int(16000 / hzPerBin)]
                        var powerAtHz: [Float] = []
                        binIndexs.forEach{
                            i in
                            let magnitude = sqrt(realBP[i]  * realBP[i] + imagBP[i] * imagBP[i])
                            let power = 20 * log10(magnitude)
                            powerAtHz.append(power)
                        }
                        //print("Power: \(powerAtHz)")
                        completion(powerAtHz)
                    }
                }
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
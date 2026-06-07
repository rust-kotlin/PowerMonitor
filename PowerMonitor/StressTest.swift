import Foundation
import Metal

// Debug-only stress workloads used to validate thermals, charts, and fan behavior.
enum StressTestMode: Equatable {
    case idle
    case cpu
    case gpu
    case cpuAndGPU
}

final class StressTestController: ObservableObject {
    @Published private(set) var mode: StressTestMode = .idle

    private var cpuWorkers: [CpuStressWorker] = []
    private var gpuWorker: GpuStressWorker?

    func startCPU() {
        stopAll()
        startCPUWorkers()
        mode = .cpu
    }

    func startGPU() {
        stopAll()
        startGPUWorker()
        mode = gpuWorker == nil ? .idle : .gpu
    }

    func startCPUAndGPU() {
        stopAll()
        startCPUWorkers()
        startGPUWorker()
        mode = gpuWorker == nil ? .cpu : .cpuAndGPU
    }

    func stopAll() {
        cpuWorkers.forEach { $0.stop() }
        cpuWorkers.removeAll()
        gpuWorker?.stop()
        gpuWorker = nil
        mode = .idle
    }

    // Match the number of CPU workers to the available logical cores for predictable saturation.
    private func startCPUWorkers() {
        let workerCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        cpuWorkers = (0..<workerCount).map { _ in
            let worker = CpuStressWorker()
            worker.start()
            return worker
        }
    }

    private func startGPUWorker() {
        let worker = GpuStressWorker()
        worker.start()
        gpuWorker = worker.isRunning ? worker : nil
    }
}

private final class CpuStressWorker {
    private let queue = DispatchQueue(label: "com.powermonitor.stress.cpu", qos: .userInitiated)
    private let stateLock = NSLock()
    private var shouldRun = false
    private var checksum: Double = 0

    func start() {
        setShouldRun(true)
        queue.async { [weak self] in
            self?.runLoop()
        }
    }

    func stop() {
        setShouldRun(false)
    }

    // Write the last result back to a property so the optimizer cannot treat the loop as dead code.
    private func runLoop() {
        var x = 0.0001
        while currentShouldRun {
            for iteration in 0..<200_000 {
                x = sin(x) * cos(x + 0.000001) + tanh(x * 1.0001)
                if x.isNaN || x.isInfinite {
                    x = 0.0001
                }
                if iteration % 10_000 == 0, !currentShouldRun {
                    return
                }
            }
            checksum = x
        }
    }

    private var currentShouldRun: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldRun
    }

    private func setShouldRun(_ newValue: Bool) {
        stateLock.lock()
        shouldRun = newValue
        stateLock.unlock()
    }
}

private final class GpuStressWorker {
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLComputePipelineState?
    private let bufferA: MTLBuffer?
    private let bufferB: MTLBuffer?
    private let workerQueue = DispatchQueue(label: "com.powermonitor.stress.gpu", qos: .userInitiated)
    private let stateLock = NSLock()
    private var shouldRun = false

    var isRunning: Bool { pipeline != nil && queue != nil && bufferA != nil && bufferB != nil }

    init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.queue = device?.makeCommandQueue()

        // A tiny compute kernel is enough here; the goal is sustained GPU work, not useful output.
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void stressKernel(
            device float *input [[buffer(0)]],
            device float *output [[buffer(1)]],
            uint id [[thread_position_in_grid]]
        ) {
            float value = input[id];
            for (uint i = 0; i < 4096; ++i) {
                value = sin(value) * cos(value) + sqrt(fabs(value) + 0.0001);
            }
            output[id] = value;
        }
        """

        if let device,
           let library = try? device.makeLibrary(source: source, options: nil),
           let function = library.makeFunction(name: "stressKernel") {
            self.pipeline = try? device.makeComputePipelineState(function: function)
        } else {
            self.pipeline = nil
        }

        let elementCount = 1 << 20
        let bufferLength = elementCount * MemoryLayout<Float>.stride
        self.bufferA = device?.makeBuffer(length: bufferLength, options: .storageModeShared)
        self.bufferB = device?.makeBuffer(length: bufferLength, options: .storageModeShared)

        if let pointer = bufferA?.contents().bindMemory(to: Float.self, capacity: elementCount) {
            for index in 0..<elementCount {
                pointer[index] = Float(index % 97) / 97.0
            }
        }
    }

    func start() {
        guard isRunning else { return }
        setShouldRun(true)
        workerQueue.async { [weak self] in
            self?.runLoop()
        }
    }

    func stop() {
        setShouldRun(false)
    }

    private func runLoop() {
        guard let queue, let pipeline, let bufferA, let bufferB else { return }

        let elementCount = bufferA.length / MemoryLayout<Float>.stride
        let gridSize = MTLSize(width: elementCount, height: 1, depth: 1)
        let threadgroupWidth = max(1, min(pipeline.maxTotalThreadsPerThreadgroup, 256))
        let threadsPerGroup = MTLSize(width: threadgroupWidth, height: 1, depth: 1)

        while currentShouldRun {
            autoreleasepool {
                guard let commandBuffer = queue.makeCommandBuffer(),
                      let encoder = commandBuffer.makeComputeCommandEncoder()
                else { return }

                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(bufferA, offset: 0, index: 0)
                encoder.setBuffer(bufferB, offset: 0, index: 1)
                encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
                encoder.endEncoding()
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
            }
        }
    }

    private var currentShouldRun: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldRun
    }

    private func setShouldRun(_ newValue: Bool) {
        stateLock.lock()
        shouldRun = newValue
        stateLock.unlock()
    }
}

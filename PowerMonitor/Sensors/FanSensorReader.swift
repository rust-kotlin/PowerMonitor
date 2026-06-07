import Foundation

final class FanSensorReader {
    private let smc = SMCConnection()

    func readFans() -> [FanReading] {
        guard let fanCount = smc.readNumericValue("FNum") else { return [] }

        let count = max(0, min(Int(fanCount), 8))
        var result: [FanReading] = []
        for index in 0..<count {
            let currentKey = String(format: "F%dAc", index)
            let minKey = String(format: "F%dMn", index)
            let maxKey = String(format: "F%dMx", index)

            guard let rpm = smc.readNumericValue(currentKey) else { continue }
            let minRPM = smc.readNumericValue(minKey)
            let maxRPM = smc.readNumericValue(maxKey)
            result.append(FanReading(id: index, rpm: rpm, minRPM: minRPM, maxRPM: maxRPM))
        }
        return result
    }
}

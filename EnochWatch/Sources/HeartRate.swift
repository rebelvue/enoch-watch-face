import Foundation
import HealthKit

/// Live heart rate from HealthKit (read-only). nil until a sample arrives or when access is denied.
final class HeartRate: ObservableObject {
    @Published var bpm: Int? = nil
    @Published var at: Date? = nil
    @Published var lo: Int? = nil   // last-hour min
    @Published var hi: Int? = nil   // last-hour max
    private var pts: [(Date, Double)] = []
    private let store = HKHealthStore()
    private var query: HKAnchoredObjectQuery?

    init() {
        guard HKHealthStore.isHealthDataAvailable(), let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        store.requestAuthorization(toShare: nil, read: [type]) { [weak self] ok, _ in if ok { self?.start(type) } }
    }

    private func start(_ type: HKQuantityType) {
        let since = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-3600), end: nil, options: .strictStartDate)
        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
            let u = HKUnit.count().unitDivided(by: .minute())
            let new = ((samples as? [HKQuantitySample]) ?? []).map { ($0.endDate, $0.quantity.doubleValue(for: u)) }
            guard !new.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let cut = Date().addingTimeInterval(-3600)
                self.pts = (self.pts + new).filter { $0.0 > cut }
                if let s = self.pts.max(by: { $0.0 < $1.0 }) { self.bpm = Int(s.1.rounded()); self.at = s.0 }
                self.lo = self.pts.map { $0.1 }.min().map { Int($0.rounded()) }; self.hi = self.pts.map { $0.1 }.max().map { Int($0.rounded()) }
            }
        }
        let q = HKAnchoredObjectQuery(type: type, predicate: since, anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        q.updateHandler = handler
        query = q; store.execute(q)
    }
}

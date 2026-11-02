import Foundation
import HealthKit

/// Live heart rate from HealthKit (read-only). nil until a sample arrives or when access is denied.
final class HeartRate: ObservableObject {
    @Published var bpm: Int? = nil
    @Published var at: Date? = nil
    private let store = HKHealthStore()
    private var query: HKAnchoredObjectQuery?

    init() {
        guard HKHealthStore.isHealthDataAvailable(), let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        store.requestAuthorization(toShare: nil, read: [type]) { [weak self] ok, _ in if ok { self?.start(type) } }
    }

    private func start(_ type: HKQuantityType) {
        let since = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-3600), end: nil, options: .strictStartDate)
        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
            guard let s = (samples as? [HKQuantitySample])?.max(by: { $0.endDate < $1.endDate }) else { return }
            let v = s.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            DispatchQueue.main.async { self?.bpm = Int(v.rounded()); self?.at = s.endDate }
        }
        let q = HKAnchoredObjectQuery(type: type, predicate: since, anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        q.updateHandler = handler
        query = q; store.execute(q)
    }
}

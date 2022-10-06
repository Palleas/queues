#if compiler(>=5.5) && canImport(_Concurrency)
import Metrics
import Queues
import Vapor
import XCTVapor
import XCTQueues
@testable import CoreMetrics
@testable import Vapor
import NIOConcurrencyHelpers

@available(macOS 12, iOS 15, watchOS 8, tvOS 15, *)
final class MetricsTests: XCTestCase {
    func testJobDurationTimer() throws {
        let metrics = CapturingMetricsSystem()
        MetricsSystem.bootstrapInternal(metrics)
        
        let app = Application(.testing)
        defer { app.shutdown() }
        app.queues.use(.test)
        
        let promise = app.eventLoopGroup.next().makePromise(of: Void.self)
        app.queues.add(MyAsyncJob(promise: promise))
        
        app.get("foo") { req async throws -> String in
            try await req.queue.dispatch(MyAsyncJob.self, .init(foo: "bar"), id: JobIdentifier(string: "some-id"))
            return "done"
        }
        
        try app.testable().test(.GET, "foo") { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "done")
        }
        
        try app.queues.queue.worker.run().wait()
        
        let timer = metrics.timers["some-id.jobDurationTimer"] as! TestTimer
        let successDimension = try XCTUnwrap(timer.dimensions.first(where: { $0.0 == "success" }))
        let idDimension = try XCTUnwrap(timer.dimensions.first(where: { $0.0 == "id" }))
        XCTAssertEqual(successDimension.1, "true")
        XCTAssertEqual(idDimension.1, "some-id")
        
        try XCTAssertNoThrow(promise.futureResult.wait())
    }
    
    func testSuccessfullyCompletedJobsCounter() {
        let metrics = CapturingMetricsSystem()
        MetricsSystem.bootstrapInternal(metrics)

        let app = Application(.testing)
        app.queues.use(.test)
        defer { app.shutdown() }

        let promise = app.eventLoopGroup.next().makePromise(of: String.self)
        app.queues.add(Foo(promise: promise))

        app.get("foo") { req in
            try await req.queue.dispatch(MyAsyncJob.self, .init(foo: "bar"), id: JobIdentifier(string: "first"))
            try await req.queue.dispatch(MyAsyncJob.self, .init(foo: "rab"), id: JobIdentifier(string: "second"))
            return "done"
        }
    }
}

internal final class CapturingMetricsSystem: MetricsFactory {
    private let lock = NIOLock()
    var counters = [String: CounterHandler]()
    var recorders = [String: RecorderHandler]()
    var timers = [String: TimerHandler]()

    public func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        return self.make(label: label, dimensions: dimensions, registry: &self.counters, maker: TestCounter.init)
    }

    public func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        let maker = { (label: String, dimensions: [(String, String)]) -> RecorderHandler in
            TestRecorder(label: label, dimensions: dimensions, aggregate: aggregate)
        }
        return self.make(label: label, dimensions: dimensions, registry: &self.recorders, maker: maker)
    }

    public func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        return self.make(label: label, dimensions: dimensions, registry: &self.timers, maker: TestTimer.init)
    }

    private func make<Item>(label: String, dimensions: [(String, String)], registry: inout [String: Item], maker: (String, [(String, String)]) -> Item) -> Item {
        return self.lock.withLock {
            let item = maker(label, dimensions)
            registry[label] = item
            return item
        }
    }

    func destroyCounter(_ handler: CounterHandler) {
        if let testCounter = handler as? TestCounter {
            self.counters.removeValue(forKey: testCounter.label)
        }
    }

    func destroyRecorder(_ handler: RecorderHandler) {
        if let testRecorder = handler as? TestRecorder {
            self.recorders.removeValue(forKey: testRecorder.label)
        }
    }

    func destroyTimer(_ handler: TimerHandler) {
        if let testTimer = handler as? TestTimer {
            self.timers.removeValue(forKey: testTimer.label)
        }
    }
}

internal class TestCounter: CounterHandler, Equatable {
    let id: String
    let label: String
    let dimensions: [(String, String)]

    let lock = NIOLock()
    var values = [(Date, Int64)]()

    init(label: String, dimensions: [(String, String)]) {
        self.id = UUID().uuidString
        self.label = label
        self.dimensions = dimensions
    }

    func increment(by amount: Int64) {
        self.lock.withLock {
            self.values.append((Date(), amount))
        }
        print("adding \(amount) to \(self.label)")
    }

    func reset() {
        self.lock.withLock {
            self.values = []
        }
        print("resetting \(self.label)")
    }

    public static func == (lhs: TestCounter, rhs: TestCounter) -> Bool {
        return lhs.id == rhs.id
    }
}

internal class TestRecorder: RecorderHandler, Equatable {
    let id: String
    let label: String
    let dimensions: [(String, String)]
    let aggregate: Bool

    let lock = NIOLock()
    var values = [(Date, Double)]()

    init(label: String, dimensions: [(String, String)], aggregate: Bool) {
        self.id = UUID().uuidString
        self.label = label
        self.dimensions = dimensions
        self.aggregate = aggregate
    }

    func record(_ value: Int64) {
        self.record(Double(value))
    }

    func record(_ value: Double) {
        self.lock.withLock {
            values.append((Date(), value))
        }
        print("recording \(value) in \(self.label)")
    }

    public static func == (lhs: TestRecorder, rhs: TestRecorder) -> Bool {
        return lhs.id == rhs.id
    }
}

internal class TestTimer: TimerHandler, Equatable {
    let id: String
    let label: String
    var displayUnit: TimeUnit?
    let dimensions: [(String, String)]

    let lock = NIOLock()
    var values = [(Date, Int64)]()

    init(label: String, dimensions: [(String, String)]) {
        self.id = UUID().uuidString
        self.label = label
        self.displayUnit = nil
        self.dimensions = dimensions
    }

    func preferDisplayUnit(_ unit: TimeUnit) {
        self.lock.withLock {
            self.displayUnit = unit
        }
    }

    func retriveValueInPreferredUnit(atIndex i: Int) -> Double {
        return self.lock.withLock {
            let value = values[i].1
            guard let displayUnit = self.displayUnit else {
                return Double(value)
            }
            return Double(value) / Double(displayUnit.scaleFromNanoseconds)
        }
    }

    func recordNanoseconds(_ duration: Int64) {
        self.lock.withLock {
            values.append((Date(), duration))
        }
        print("recording \(duration) \(self.label)")
    }

    public static func == (lhs: TestTimer, rhs: TestTimer) -> Bool {
        return lhs.id == rhs.id
    }
}
#endif

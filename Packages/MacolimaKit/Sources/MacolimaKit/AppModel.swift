import Foundation
import Observation

/// One observable model behind every view. Lives in the kit so it is tested headless with `swift test`.
@MainActor @Observable
public final class AppModel {
    public enum Connection: Equatable {
        /// Talking to the engine; data is current.
        case live
        /// Colima is up but the daemon refuses connections; data is as of the date (`.distantPast` = no data).
        case stale(Date)
        /// The Colima VM is not running; data (if any) is the last snapshot.
        case colimaStopped(lastSnapshot: Date?)
        /// Socket missing or another engine error; the message says what and what to do.
        case unreachable(String)
    }

    public private(set) var connection: Connection = .colimaStopped(lastSnapshot: nil)
    public private(set) var colima: ColimaStatus = .stopped
    public private(set) var hostDisk: DiskUsage?
    /// Bytes Docker reports using inside the VM.
    public private(set) var dockerBytes: Int64?
    public private(set) var containers: [ContainerSummary] = []
    public private(set) var images: [ImageSummary] = []
    public private(set) var volumes: [VolumeSummary] = []
    public private(set) var socket: SocketInfo?
    public private(set) var isBootstrapped = false
    public private(set) var colimaBusy = false
    /// The `colima` executable cannot be found: starting it is impossible, installing it is the next step.
    public private(set) var colimaMissing = false
    public var lastError: String?

    public var usage: UsageIndex { UsageIndex(containers: containers) }
    public var canMutate: Bool { connection == .live }

    @ObservationIgnored private let locate: @Sendable () async -> SocketInfo
    @ObservationIgnored private let engineFactory: (String) -> DockerEngine
    @ObservationIgnored private let colimaFactory: (String) -> ColimaService
    @ObservationIgnored private let store: SnapshotStore
    @ObservationIgnored private let colimaInstalled: () -> Bool
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let pollInterval: Duration?

    @ObservationIgnored var engine: DockerEngine?
    @ObservationIgnored private var colimaService: ColimaService?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var isConnecting = false
    @ObservationIgnored private var reconnectRequested = false
    @ObservationIgnored private var lastRefresh = Date.distantPast

    public init(locate: @escaping @Sendable () async -> SocketInfo = { await SocketLocator.resolve() },
                engineFactory: @escaping (String) -> DockerEngine = { DockerAPI(socketPath: $0) },
                colimaFactory: @escaping (String) -> ColimaService = { ColimaService(profile: $0) },
                store: SnapshotStore,
                colimaInstalled: @escaping () -> Bool = { Shell.find("colima") != nil },
                debounce: Duration = .milliseconds(300),
                pollInterval: Duration? = .seconds(5)) {
        self.locate = locate
        self.engineFactory = engineFactory
        self.colimaFactory = colimaFactory
        self.store = store
        self.colimaInstalled = colimaInstalled
        self.debounce = debounce
        self.pollInterval = pollInterval
    }

    // MARK: Lifecycle

    /// Resolve the socket and profile, check Colima, load live data (or the snapshot), then follow Docker events.
    public func bootstrap() async {
        let info = await locate()
        socket = info
        engine = engineFactory(info.path)
        colimaService = colimaFactory(info.profile)
        await connect()
        isBootstrapped = true
        startMonitor()
    }

    /// Re-check Colima and the engine now (the "Retry" action).
    public func reconnect() async { await connect() }

    public func startColima() async {
        await controlColima { try await $0.start() }
    }

    public func stopColima() async {
        await controlColima { try await $0.stop() }
    }

    private func controlColima(_ action: (ColimaService) async throws -> Void) async {
        guard let colimaService else { return }
        colimaBusy = true
        defer { colimaBusy = false }
        lastError = nil
        do { try await action(colimaService) } catch { lastError = Pruner.describe(error) }
        await connect()
    }

    // MARK: Connecting

    private func connect() async {
        guard !isConnecting else { reconnectRequested = true; return }
        isConnecting = true
        defer { isConnecting = false }
        repeat {
            reconnectRequested = false
            await connectOnce()
        } while reconnectRequested
    }

    private func connectOnce() async {
        guard let engine, let colimaService else { return }
        colimaMissing = !colimaInstalled()
        let status = await colimaService.status()
        colima = status
        guard case .running(let info) = status else {
            hostDisk = colimaService.hostDisk()
            stopEvents()
            let snapshot = loadSnapshot()
            connection = .colimaStopped(lastSnapshot: snapshot?.savedAt)
            return
        }
        hostDisk = colimaService.hostDisk(maxBytes: info.diskMaxBytes)
        do {
            try await engine.negotiate()
            try await refresh()
            startEvents(engine)
        } catch {
            enterOffline(error)
        }
    }

    /// Reload everything from the engine and refresh the on-disk snapshot.
    func refresh() async throws {
        guard let engine else { return }
        async let c = engine.containers()
        async let i = engine.images()
        async let v = engine.volumes()
        async let d = try? engine.diskUsage()
        let (cs, ims, vs) = try await (c, i, v)
        containers = cs
        images = ims
        volumes = vs
        dockerBytes = await d
        lastRefresh = Date()
        connection = .live
        try? store.save(Snapshot(savedAt: lastRefresh, containers: cs, images: ims, volumes: vs))
        if case .running(let info) = colima { hostDisk = colimaService?.hostDisk(maxBytes: info.diskMaxBytes) }
    }

    /// Pull fresh state after a mutation (events would do it too, but a debounced event is not a guarantee).
    func refreshAfterMutation() async {
        guard canMutate else { return }   // a refused action must not talk to the engine or flip the state
        do { try await refresh() } catch { enterOffline(error) }
    }

    private func enterOffline(_ error: Error) {
        stopEvents()
        let snapshot = loadSnapshot()
        switch error as? DockerError {
        case .connectionRefused:
            connection = .stale(snapshot?.savedAt ?? .distantPast)
        case .socketMissing:
            let path = socket?.path ?? "the Docker socket"
            connection = .unreachable("Docker socket not found at \(path). Is the Docker context pointing at Colima?")
        default:
            connection = .unreachable(Pruner.describe(error))
        }
    }

    @discardableResult
    private func loadSnapshot() -> Snapshot? {
        guard let snapshot = store.load() else { return nil }
        containers = snapshot.containers
        images = snapshot.images
        volumes = snapshot.volumes
        return snapshot
    }

    // MARK: Live updates

    private func startEvents(_ engine: DockerEngine) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            do {
                for try await event in engine.events() {
                    guard let self else { return }
                    self.handle(event)
                }
            } catch {}
            guard !Task.isCancelled else { return }
            self?.eventsEnded()
        }
    }

    private func stopEvents() {
        eventsTask?.cancel()
        eventsTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func handle(_ event: DockerEvent) {
        if case .other = event { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            do { try await self.refresh() } catch { self.enterOffline(error) }
        }
    }

    /// The event stream died while we thought we were live: the daemon went away.
    private func eventsEnded() {
        guard connection == .live else { return }
        connection = .stale(lastRefresh)
    }

    /// While not live, keep checking so live data replaces the snapshot when Colima is started elsewhere;
    /// while live, keep the host disk number current.
    private func startMonitor() {
        monitorTask?.cancel()
        guard let pollInterval else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                if self.connection == .live {
                    if case .running(let info) = self.colima { self.hostDisk = self.colimaService?.hostDisk(maxBytes: info.diskMaxBytes) }
                } else {
                    await self.connect()
                }
            }
        }
    }
}

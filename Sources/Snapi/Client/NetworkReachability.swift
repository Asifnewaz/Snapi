// NetworkReachability.swift
// NetworkingSDK
//
// Real-time network connectivity monitor built on NWPathMonitor (Network.framework).
// Does NOT poll — events are push-based from the OS.
// Use to gate requests, show offline banners, or trigger retry queues.

import Foundation
import Network

// MARK: - ConnectionType

/// The type of network interface currently active.
public enum ConnectionType: Equatable, CustomStringConvertible {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case other
    case none

    public var description: String {
        switch self {
        case .wifi:          return "Wi-Fi"
        case .cellular:      return "Cellular"
        case .wiredEthernet: return "Ethernet"
        case .loopback:      return "Loopback"
        case .other:         return "Other"
        case .none:          return "No Connection"
        }
    }
}

// MARK: - ReachabilityStatus

public struct ReachabilityStatus: Equatable {
    public let isConnected: Bool
    public let connectionType: ConnectionType
    public let isExpensive: Bool        // e.g. cellular hotspot
    public let isConstrained: Bool      // Low Data Mode

    public static let disconnected = ReachabilityStatus(
        isConnected: false,
        connectionType: .none,
        isExpensive: false,
        isConstrained: false
    )
}

// MARK: - NetworkReachability

/// Singleton network reachability monitor.
///
/// Usage:
/// ```swift
/// NetworkReachability.shared.onStatusChange = { status in
///     if !status.isConnected {
///         showOfflineBanner()
///     }
/// }
/// NetworkReachability.shared.startMonitoring()
/// ```
public final class NetworkReachability {

    // MARK: - Singleton

    public static let shared = NetworkReachability()

    // MARK: - Public Interface

    /// Current connectivity status. Updated on every path change.
    public private(set) var status: ReachabilityStatus = .disconnected

    /// Called on `callbackQueue` whenever connectivity changes.
    public var onStatusChange: ((ReachabilityStatus) -> Void)?

    /// Queue on which `onStatusChange` is called. Defaults to main.
    public var callbackQueue: DispatchQueue = .main

    // MARK: - Private

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.networkingsdk.reachability", qos: .utility)

    // MARK: - Init

    private init() {
        self.monitor = NWPathMonitor()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Control

    /// Starts monitoring. Safe to call multiple times.
    public func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let newStatus = ReachabilityStatus(from: path)
            guard newStatus != self.status else { return }
            self.status = newStatus
            self.callbackQueue.async {
                self.onStatusChange?(newStatus)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    /// Stops monitoring and releases the path observer.
    public func stopMonitoring() {
        monitor.cancel()
        onStatusChange = nil
    }

    // MARK: - Convenience

    /// Synchronously checks current connectivity.
    public var isConnected: Bool { status.isConnected }

    /// Returns current connection type.
    public var connectionType: ConnectionType { status.connectionType }
}

// MARK: - ReachabilityStatus from NWPath

private extension ReachabilityStatus {
    init(from path: NWPath) {
        let connected = path.status == .satisfied
        isConnected = connected
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained

        if !connected {
            connectionType = .none
        } else if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionType = .wiredEthernet
        } else if path.usesInterfaceType(.loopback) {
            connectionType = .loopback
        } else {
            connectionType = .other
        }
    }
}

// MARK: - APIClient + Reachability Guard

public extension APIClient {

    /// Checks reachability before executing a GET. Returns `.transportError` immediately
    /// if offline — avoids queuing a doomed request.
    func getIfReachable<T: Decodable>(
        path: String,
        queryParameters: [String: String]? = nil,
        headers: [String: String]? = nil,
        reachability: NetworkReachability = .shared,
        completion: @escaping (Result<T, NetworkError>) -> Void
    ) {
        guard reachability.isConnected else {
            let offline = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet,
                userInfo: [NSLocalizedDescriptionKey: "Device is offline"]
            )
            DispatchQueue.main.async { completion(.failure(.transportError(offline))) }
            return
        }
        get(path: path, queryParameters: queryParameters, headers: headers, completion: completion)
    }
}

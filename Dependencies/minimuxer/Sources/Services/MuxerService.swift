//
//  MuxerService.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import Network

final internal class MuxerService {
    static let shared = MuxerService()

    private var maxBufferLen: Int { MinimuxerConstants.usbmuxMaxPacketBufferLength }
    private var headerLen: Int { MinimuxerConstants.usbmuxHeaderLen }

    private(set) var started = false
    private(set) var isListening = false

    private var deviceUDID: String?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "minimuxer.MuxerService", qos: .userInitiated)

    // Stable device state
    private var currentDeviceIp: String?
    private var currentEvent: String?

    func notifyDeviceAttached(tunnelPeerIp: String) {
        currentDeviceIp = tunnelPeerIp
        currentEvent = MinimuxerConstants.deviceAttach
    }
    func notifyDeviceDetached() {
        currentDeviceIp = nil
        currentEvent = MinimuxerConstants.deviceDetach
    }

    // Binds a TCP server on 127.0.0.1:27015 and accepts incoming connections
    // from libusbmuxd. This is our fake usbmuxd — it speaks
    // just enough of the usbmuxd protocol for the library to discover the
    // device, read the pairing record, and open services (AFC, lockdown, etc.).
    @discardableResult
    func start(udid: String) async throws -> Bool {
        guard !started else {
            verboseLog("[minimuxer] Already started MuxerService, skipping")
            return false
        }
        deviceUDID = udid
        isListening = false

        guard let port = NWEndpoint.Port(rawValue: MinimuxerConstants.usbmuxdPort) else {
            throw MinimuxerError.connect("Invalid usbmuxd port: \(MinimuxerConstants.usbmuxdPort)")
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let newListener = try NWListener(using: params, on: port)

        return try await withCheckedThrowingContinuation { continuation in
            var hasResponded = false

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                    case .ready:
                        verboseLog("[minimuxer] MuxerService (NWListener) bound successfully to \(MinimuxerConstants.usbmuxdHost):\(MinimuxerConstants.usbmuxdPort)")
                        self.isListening = true
                        self.started = true
                        if !hasResponded {
                            hasResponded = true
                            continuation.resume(returning: true)
                        }
                    case .failed(let error):
                        debugLog("[minimuxer] MuxerService listener failed with error: \(error)")
                        self.isListening = false
                        self.started = false
                        if !hasResponded {
                            hasResponded = true
                            continuation.resume(throwing: MinimuxerError.connect("MuxerService failed to bind: \(error.localizedDescription)"))
                        }
                    case .cancelled:
                        self.isListening = false
                        self.started = false
                    default:
                        break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener = newListener
            newListener.start(queue: queue)
        }
    }

    func stop() async {
        guard started else { return }
        let currentListener = listener
        started = false
        isListening = false
        deviceUDID = nil
        listener = nil

        guard let currentListener = currentListener else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var hasResponded = false
            currentListener.stateUpdateHandler = { state in
                if case .cancelled = state {
                    if !hasResponded {
                        hasResponded = true
                        continuation.resume()
                    }
                }
            }
            currentListener.cancel()
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveNextPacket(on: connection)
    }
    private func receiveNextPacket(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxBufferLen) { [weak self] data, context, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }

            // libimobiledevice sometimes sends the 16-byte packet header in
            // one write and the plist body in a follow-up write. If we only
            // got the header, block for the body before trying to parse.
            if data.count == self.headerLen {
                let maxBodyLen = self.maxBufferLen - self.headerLen
                connection.receive(minimumIncompleteLength: 1, maximumLength: maxBodyLen) { [weak self] bodyData, _, _, _ in
                    guard let self = self else { return }
                    var fullData = data
                    if let bodyData = bodyData {
                        fullData.append(bodyData)
                    }
                    self.processPacketData(fullData, on: connection)
                }
            } else {
                self.processPacketData(data, on: connection)
            }
        }
    }

    private func processPacketData(_ data: Data, on connection: NWConnection) {
        defer {
            receiveNextPacket(on: connection)
        }

        guard let packet = RawPacket(data: data) else { return }

        do {
            let response = try handlePacket(packet)
            let responsePacket = RawPacket(plist: response, version: 1, message: 8, tag: packet.tag)
            let responseData = responsePacket.data

            connection.send(content: responseData, completion: .contentProcessed({ error in
                if let error = error {
                    debugLog("[minimuxer] MuxerService send error: \(error)")
                }
            }))
        } catch {}
    }

    // MARK: - Packet Handling

    // Responds to the only usbmuxd protocol message("ListDevices") that
    // idevice requires to establish lockdown session when using lockdown based pairing file
    // (lockdown requires UDID to start session, so our server responds with data read from pair file)
    private func handlePacket(_ packet: RawPacket) throws -> [String: Any] {
        guard let messageType = packet.plist["MessageType"] as? String else {
            throw MinimuxerError.connect("Malformed usbmuxd packet: missing MessageType field")
        }

        verboseLog("[minimuxer] usbmux message: \(messageType)")

        switch messageType {
            case "ListDevices":
                guard let tunnelIfaceIp = currentDeviceIp else {
                    return ["DeviceList": []]
                }
                guard let udid = deviceUDID else {
                    throw MinimuxerError.invalidPairing(protocol: .lockdown, reason: "No device UDID available for ListDevices response")
                }
                let payload: [String: Any] = [
                    "DeviceID": 0,                                                      // don't care
                    "Properties": [
                        "ConnectionType": "Network",                                    // using 'network' protocol of usbmuxd
                        "DeviceID": 0,                                                  // fake device id
                        "EscapedFullServiceName": "\(udid)._apple-mobdev2._tcp.local",  // advert for mds discovery
                        "InterfaceIndex": 0,                                            // don't care
                        "NetworkAddress": convertIp(tunnelIfaceIp),                     // remote IP where device's lockdownd is accepting requests on
                        "SerialNumber": udid                                            // device UDID
                    ]
                ]
                return ["DeviceList": [payload]]
            default:
                debugLog("[minimuxer] WARN: unknown message type: \(messageType)")
                throw MinimuxerError.connect("Unsupported usbmuxd message type: \(messageType)")
        }
    }

    // Encodes an IPv4 address into the 152-byte sockaddr_storage layout that
    // libusbmuxd expects in the NetworkAddress field of the device properties.
    private func convertIp(_ ip: String) -> Data {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)

        var data = Data(count: 152)
        if inet_pton(AF_INET, ip, &sa.sin_addr) == 1 {
            withUnsafeBytes(of: sa) { src in
                data.withUnsafeMutableBytes { dst in
                    dst.copyMemory(from: src)
                }
            }
        }
        return data
    }
}

import Foundation
import Network
import Security

/// Network-level configuration for reaching a broker.
public struct TransportConfiguration: @unchecked Sendable {
    public var host: String
    public var port: UInt16
    public var useTLS: Bool
    public var useWebSocket: Bool
    public var webSocketPath: String
    public var validateCertificate: Bool
    public var caCertificates: [SecCertificate]
    public var clientIdentity: SecIdentity?
    public var alpnProtocols: [String]
    public var connectTimeout: TimeInterval

    public init(
        host: String, port: UInt16, useTLS: Bool = false, useWebSocket: Bool = false,
        webSocketPath: String = "/mqtt", validateCertificate: Bool = true,
        caCertificates: [SecCertificate] = [], clientIdentity: SecIdentity? = nil,
        alpnProtocols: [String] = [], connectTimeout: TimeInterval = 15
    ) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.useWebSocket = useWebSocket
        self.webSocketPath = webSocketPath
        self.validateCertificate = validateCertificate
        self.caCertificates = caCertificates
        self.clientIdentity = clientIdentity
        self.alpnProtocols = alpnProtocols
        self.connectTimeout = connectTimeout
    }

    public var urlDescription: String {
        let scheme = useWebSocket ? (useTLS ? "wss" : "ws") : (useTLS ? "mqtts" : "mqtt")
        let path = useWebSocket ? normalizedPath : ""
        return "\(scheme)://\(host):\(port)\(path)"
    }

    var normalizedPath: String {
        let p = webSocketPath.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return "/" }
        return p.hasPrefix("/") ? p : "/" + p
    }

    func makeConnection(queue: DispatchQueue) throws -> NWConnection {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(connectTimeout)
        tcp.noDelay = true

        var tlsOptions: NWProtocolTLS.Options?
        if useTLS {
            let tls = NWProtocolTLS.Options()
            let sec = tls.securityProtocolOptions
            let validate = validateCertificate
            let anchors = caCertificates
            sec_protocol_options_set_verify_block(sec, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard validate else { complete(true); return }
                if !anchors.isEmpty {
                    SecTrustSetAnchorCertificates(secTrust, anchors as CFArray)
                    SecTrustSetAnchorCertificatesOnly(secTrust, false)
                }
                var error: CFError?
                complete(SecTrustEvaluateWithError(secTrust, &error))
            }, queue)
            if let identity = clientIdentity, let secIdentity = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(sec, secIdentity)
            }
            for proto in alpnProtocols where !proto.isEmpty {
                sec_protocol_options_add_tls_application_protocol(sec, proto)
            }
            tlsOptions = tls
        }

        let params = NWParameters(tls: tlsOptions, tcp: tcp)

        if useWebSocket {
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            ws.setSubprotocols(["mqtt"])
            ws.maximumMessageSize = 256 * 1024 * 1024
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            var comps = URLComponents()
            comps.scheme = useTLS ? "wss" : "ws"
            comps.host = host
            comps.port = Int(port)
            comps.path = normalizedPath
            guard let url = comps.url else { throw MQTTError.transport("Invalid WebSocket URL") }
            return NWConnection(to: .url(url), using: params)
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw MQTTError.transport("Invalid port \(port)") }
        return NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
    }
}

// MARK: - Certificate helpers

public enum CertificateLoader {
    /// Parses one or more certificates from PEM text or raw DER data.
    public static func certificates(from data: Data) throws -> [SecCertificate] {
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            var result: [SecCertificate] = []
            let blocks = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
            for block in blocks {
                guard let body = block.components(separatedBy: "-----END CERTIFICATE-----").first else { continue }
                let b64 = body.components(separatedBy: .whitespacesAndNewlines).joined()
                guard let der = Data(base64Encoded: b64),
                      let cert = SecCertificateCreateWithData(nil, der as CFData) else {
                    throw MQTTError.transport("Could not parse PEM certificate")
                }
                result.append(cert)
            }
            return result
        }
        guard let cert = SecCertificateCreateWithData(nil, data as CFData) else {
            throw MQTTError.transport("File is not a PEM or DER encoded certificate")
        }
        return [cert]
    }

    /// Imports a client identity from a PKCS#12 (.p12 / .pfx) archive.
    public static func identity(fromPKCS12 data: Data, password: String) throws -> SecIdentity {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw MQTTError.transport("Could not import client certificate: \(message)")
        }
        guard let array = items as? [[String: Any]],
              let first = array.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw MQTTError.transport("The PKCS#12 file contains no identity")
        }
        return identityRef as! SecIdentity // swiftlint:disable:this force_cast
    }

    public static func summary(of certificate: SecCertificate) -> String {
        (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Certificate"
    }
}

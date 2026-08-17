//
//  ALTCertificate.swift
//  AltSign
//

import Foundation
import SwiftBridge


public final class ALTX509Certificate: NSObject, Identifiable {

    public var id: String { serialNumber }

    // MARK: Properties

    public var name: String
    public var serialNumber: String

    public var identifier: String?
    public var machineName: String?
    public var machineIdentifier: String?
    public var requesterEmail: String?

    public var creationDate: Date = Date.distantPast
    public var expiryDate: Date = Date.distantPast

    public var data: Data?

    // MARK: PEM Constants

    fileprivate static let pemPrefix = "-----BEGIN CERTIFICATE-----"
    fileprivate static let pemSuffix = "-----END CERTIFICATE-----"

    // MARK: Designated Init

    public init(name: String, serialNumber: String, data: Data?, creationDate: Date = Date.distantPast, expiryDate: Date = Date.distantPast) {
        self.name = name
        self.serialNumber = serialNumber
        self.data = data
        self.creationDate = creationDate
        self.expiryDate = expiryDate
        super.init()
    }

    // MARK: Response Init

    public convenience init?(responseDictionary: [String: Any]) {
        let identifier = responseDictionary["id"] as? String
        let attributes =
            (responseDictionary["attributes"] as? [String: Any])
            ?? responseDictionary

        var certData: Data?

        if let data = attributes["certContent"] as? Data {
            certData = data
        } else if let base64 = attributes["certificateContent"] as? String {
            certData = Data(base64Encoded: base64)
        }

        let machineName =
            (attributes["machineName"] as? NSNull) == nil
            ? attributes["machineName"] as? String
            : nil

        let machineIdentifier =
            (attributes["machineId"] as? NSNull) == nil
            ? attributes["machineId"] as? String
            : nil

        if let certData {
            self.init(data: certData)
        } else {
            guard
                let name = attributes["name"] as? String,
                let serial =
                    (attributes["serialNumber"]
                     ?? attributes["serialNum"]) as? String
            else { return nil }

            self.init(name: name, serialNumber: serial, data: nil)
        }

        self.identifier = identifier
        self.machineName = machineName
        self.machineIdentifier = machineIdentifier
        self.requesterEmail = attributes["requesterEmail"] as? String

        let dateFormatter = ISO8601DateFormatter()
        if let creationString = attributes["createdDate"] as? String, let date = dateFormatter.date(from: creationString) {
            self.creationDate = date
        }
        if let expirationString = attributes["expirationDate"] as? String, let date = dateFormatter.date(from: expirationString) {
            self.expiryDate = date
        }
    }

    // MARK: PEM Init

    public convenience init?(data: Data) {
        var pemData = data

        if let prefix = String(
            data: data.prefix(Self.pemPrefix.count),
            encoding: .utf8
        ),
        prefix != Self.pemPrefix {
            let base64 = data.base64EncodedString(
                options: .lineLength64Characters
            )
            let content = "\(Self.pemPrefix)\n\(base64)\n\(Self.pemSuffix)"
            pemData = content.data(using: .utf8)!
        }

        guard let parsed = CertificatesManager.parseCertificate(pemData) else { return nil }

        var serial = parsed.serial
        if let idx = serial.firstIndex(where: { $0 != "0" }) {
            serial = String(serial[idx...])
        } else {
            return nil
        }

        self.init(
            name: parsed.name,
            serialNumber: serial,
            data: pemData,
            creationDate: parsed.creationDate ?? .distantPast,
            expiryDate: parsed.expiryDate ?? .distantPast
        )
    }

    // MARK: NSObject

    public override var description: String {
        "<\(NSStringFromClass(Swift.type(of: self))): \(Unmanaged.passUnretained(self).toOpaque()), Name: \(name), SN: \(serialNumber)>"
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ALTX509Certificate else {
            return false
        }
        return serialNumber == other.serialNumber
    }

    public override var hash: Int {
        serialNumber.hashValue
    }
}

public final class ALTCertificate: NSObject, Identifiable {

    public var id: String { serialNumber }

    // MARK: Properties

    public var x509: ALTX509Certificate
    public var privateKey: Data

    // Forwarded Properties for Compatibility
    public var name:              String  { get { x509.name }              set { x509.name = newValue } }
    public var serialNumber:      String  { get { x509.serialNumber }      set { x509.serialNumber = newValue } }
    public var identifier:        String? { get { x509.identifier }        set { x509.identifier = newValue } }
    public var machineName:       String? { get { x509.machineName }       set { x509.machineName = newValue } }
    public var machineIdentifier: String? { get { x509.machineIdentifier } set { x509.machineIdentifier = newValue } }
    public var requesterEmail:    String? { get { x509.requesterEmail }    set { x509.requesterEmail = newValue } }
    public var data:              Data?   { get { x509.data }              set { x509.data = newValue } }

    // MARK: Designated Init

    public init(x509: ALTX509Certificate, privateKey: Data) {
        self.x509 = x509
        self.privateKey = privateKey
        super.init()
    }

    public convenience init?(name: String, serialNumber: String, data: Data?, privateKey: Data?) {
        guard let privateKey = privateKey else { return nil }
        let x509 = ALTX509Certificate(name: name, serialNumber: serialNumber, data: data)
        self.init(x509: x509, privateKey: privateKey)
    }

    public convenience init?(x509: ALTX509Certificate, privateKey: Data?) {
        guard let privateKey = privateKey else { return nil }
        self.init(x509: x509, privateKey: privateKey)
    }

    // MARK: P12 Init

    /// Unencrypted PKCS#12 Init (pass = nil)
    public convenience init(p12Data: Data) throws {
        try self.init(p12Data: p12Data, password: nil)
    }

    /// Encrypted PKCS#12 Init (pass = password, including "")
    public convenience init(
        p12Data: Data,
        password: String?
    ) throws {
        guard p12Data.isPKCS12 else {
            throw ALTCertificateError.invalidFormat(cause: "The data does not start with a valid PKCS12 sequence.")
        }

        let result: (cert: Data, key: Data)
        do {
            result = try CertificatesManager.extractPKCS12(p12Data, password: password)
        } catch CertificatesManager.Error.operationFailed(let reason) {
            throw ALTCertificateError.extractionFailed(cause: reason)
        }

        var pemData = result.cert

        if let prefix = String(
            data: pemData.prefix(ALTX509Certificate.pemPrefix.count),
            encoding: .utf8
        ),
        prefix != ALTX509Certificate.pemPrefix {
            let base64 = pemData.base64EncodedString(
                options: .lineLength64Characters
            )
            let content = "\(ALTX509Certificate.pemPrefix)\n\(base64)\n\(ALTX509Certificate.pemSuffix)"
            pemData = content.data(using: .utf8)!
        }

        guard let parsed = CertificatesManager.parseCertificate(pemData) else {
            throw ALTCertificateError.extractionFailed(cause: "Failed to parse certificate subject or fields. OpenSSL: \(getOpenSSLError())")
        }

        var serial = parsed.serial
        if let idx = serial.firstIndex(where: { $0 != "0" }) {
            serial = String(serial[idx...])
        } else {
            throw ALTCertificateError.extractionFailed(cause: "The parsed certificate has a missing or empty serial number.")
        }

        let x509 = ALTX509Certificate(name: parsed.name, serialNumber: serial, data: pemData)
        self.init(x509: x509, privateKey: result.key)
    }

    // MARK: PEM Init

    public convenience init?(data: Data, privateKey: Data) {
        guard let x509 = ALTX509Certificate(data: data) else { return nil }
        self.init(x509: x509, privateKey: privateKey)
    }

    // MARK: NSObject

    public override var description: String {
        "<\(NSStringFromClass(Swift.type(of: self))): \(Unmanaged.passUnretained(self).toOpaque()), Name: \(name), SN: \(serialNumber), HasPrivateKey: \(privateKey != nil)>"
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ALTCertificate else {
            return false
        }
        return serialNumber == other.serialNumber
    }

    public override var hash: Int {
        serialNumber.hashValue
    }

    // MARK: P12 Export

    /// Unencrypted PKCS#12 Export (pass = nil)
    public func unencryptedP12Data() throws -> Data {
        try encryptedP12Data(password: nil)
    }

    /// Encrypted PKCS#12 Export (pass = password, including "")
    public func encryptedP12Data(password: String?) throws -> Data {
        guard let certData = data else {
            throw ALTCertificateError.extractionFailed(cause: "Certificate PEM data is missing.")
        }
        return try CertificatesManager.createPKCS12(
            cert: certData,
            key: privateKey,
            password: password
        )
    }
}

public extension Data {
    var isPKCS12: Bool {
        guard self.count > 6 else { return false }
        guard self[0] == 0x30 else { return false } // Must be SEQUENCE
        
        // Parse ASN.1 length
        var offset = 1
        let lengthByte = self[offset]
        if lengthByte & 0x80 == 0 {
            // Short form length (1 byte)
            offset += 1
        } else {
            // Long form length
            let numLengthBytes = Int(lengthByte & 0x7F)
            guard self.count > 1 + numLengthBytes else { return false }
            offset += 1 + numLengthBytes
        }
        
        guard self.count > offset else { return false }
        return self[offset] == 0x02 // First element of PFX SEQUENCE must be INTEGER (version)
    }
}

public typealias ALTCertificateError = SwiftBridge.ALTCertificateError
public typealias MachOParser = SwiftBridge.MachOParser
public typealias MachOParserError = SwiftBridge.MachOParserError

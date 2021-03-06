// Copyright (c) 2018 Token Browser, Inc
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

import Foundation
import EtherealCereal
import HDWallet

/// An EtherealCereal wrapper. Generates the address and public key for a given private key. Signs messages.
class Cereal: NSObject {

    /// The underlying shared Cereal. Will be nil at first if there is no stored cereal,
    /// at which point it should be set once the user is created.
    private static var _shared: Cereal? = {
        guard let passphrase = Cereal.storedPassphrase() else {
            if UserDefaultsWrapper.hasStoredPassphraseInYap {
                fatalError("Could not retrive stored passphrase!")
            }

            return nil
        }

        return Cereal(words: passphrase)
    }()

    /// True if the underlying shared Cereal exists, false if it doesn't.
    static var hasSharedCereal: Bool {
        return _shared != nil
    }

    /// The main accessor for the shared user. If the user isn't definitely supposed to be there, check `hasSharedCereal` before calling this.
    @objc static var shared: Cereal {
        guard let cereal = _shared else {
            fatalError("Attempting to access shared cereal when it doesn't exist!")
        }

        return cereal
    }

    static func setSharedCereal(_ cereal: Cereal) {
        _shared = cereal
    }

    static let entropyByteCount = 16

    var idCereal: EtherealCereal

    var walletCereal: EtherealCereal

    var mnemonic: BTCMnemonic

    static let privateKeyStorageKey = "cerealPrivateKey"

    @objc var address: String {
        return idCereal.address
    }

    var paymentAddress: String {
        return walletCereal.address
    }

    @objc static func areWordsValid(_ words: [String]) -> Bool {
        return BTCMnemonic(words: words, password: nil, wordListType: .english) != nil
    }
    
    private static func idKeychain(from mnemonic: BTCMnemonic) -> BTCKeychain {
        // ID path 0H/1/0
        return mnemonic.keychain
            .derivedKeychain(at: 0, hardened: true)
            .derivedKeychain(at: 1)
            .derivedKeychain(at: 0)
    }
    
    private static func walletKeychain(from mnemonic: BTCMnemonic) -> BTCKeychain {
        // wallet path: 44H/60H/0H/0 and then 0 again. Metamask root path, first key.
        // Metamask allows multiple addresses, by incrementing the last path. So second key would be: 44H/60H/0H/0/1 and so on.
        return mnemonic.keychain
            .derivedKeychain(at: 44, hardened: true)
            .derivedKeychain(at: 60, hardened: true)
            .derivedKeychain(at: 0, hardened: true)
            .derivedKeychain(at: 0)
            .derivedKeychain(at: 0)
    }

    private static func storedPassphrase() -> [String]? {
        guard let words = Yap.sharedInstance.retrieveObject(for: Cereal.privateKeyStorageKey) as? String else { return nil }

        return words.components(separatedBy: " ")
    }

    // restore from words
    convenience init?(words: [String]) {
        guard let mnemonic = BTCMnemonic(words: words, password: nil, wordListType: .english) else { return nil }

        self.init(mnemonic: mnemonic)
    }

    convenience init?(entropy: Data) {
        let bits = entropy.countInBits
        guard (bits > 0) && (bits % 32 == 0)  else {
            // Attempting to create a mnemonic from entropy with a number of bytes not divisible by 32 will throw an obj-c error and crash.
            return nil
        }

        guard let mnemonic = BTCMnemonic(entropy: entropy, password: nil, wordListType: BTCMnemonicWordListType.english) else { return nil }

        self.init(mnemonic: mnemonic)
    }

    static func generateNew() -> Cereal {
        let entropy = generateEntropy()

        guard let generated = Cereal(entropy: entropy) else {
            fatalError("Could not generate cereal from entropy!")
        }
        
        return generated
    }

    private init(mnemonic: BTCMnemonic) {
        self.mnemonic = mnemonic

        // ID path 0H/1/0
        let idKeychain = Cereal.idKeychain(from: mnemonic)
        let idPrivateKey = idKeychain.key.privateKey.hexadecimalString()
        idCereal = EtherealCereal(privateKey: idPrivateKey)

        // wallet path: 44H/60H/0H/0
        let walletKeychain = Cereal.walletKeychain(from: mnemonic)
        let walletPrivateKey = walletKeychain.key.privateKey.hexadecimalString()
        walletCereal = EtherealCereal(privateKey: walletPrivateKey)

        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(userCreated(_:)), name: .userCreated, object: nil)
    }

    private override init() {
        fatalError("Don't use the empty initializer!")
    }

    static func generateEntropy() -> Data {
        var entropy = Data(count: entropyByteCount)
        // This creates the private key inside a block, result is of internal type ResultType.
        // We just need to check if it's 0 to ensure that there were no errors.
        let count = entropy.count
        let result: Int32 = entropy.withUnsafeMutableBytes { mutableBytes in
            SecRandomCopyBytes(kSecRandomDefault, count, mutableBytes)
        }
        guard result == 0 else {
            CrashlyticsLogger.log("Failed to generate random entropy data")
            fatalError("Failed to randomly generate and copy bytes for entropy generation. SecRandomCopyBytes error code: (\(result)).")
        }

        return entropy
    }

    func walletAddressQRCodeImage(resizeRate: CGFloat) -> UIImage {
        return QRCodeGenerator.qrCodeImage(for: .ethereumAddress(address: paymentAddress), resizeRate: resizeRate)
    }

    // MARK: - Sign with id

    func signWithID(message: String) -> String {
        return idCereal.sign(message: message)
    }

    func signWithID(hex: String) -> String {
        return idCereal.sign(hex: hex)
    }

    func sha3WithID(string: String) -> String {
        return idCereal.sha3(string: string)
    }

    func sha3WithID(data: Data) -> String {
        return idCereal.sha3(data: data)
    }

    // MARK: - Sign with wallet

    func signWithWallet(message: String) -> String {
        return walletCereal.sign(message: message)
    }

    func signWithWallet(hex: String) -> String {
        return walletCereal.sign(hex: hex)
    }

    func signWithWallet(hash: String) -> String {
        return walletCereal.sign(hash: hash)
    }

    func signEthereumTransactionWithWallet(hex: String) -> String? {
        do {
            guard var rlp = try RLP.decode(from: hex) as? [Data] else {
                return nil
            }
            var networkId: UInt?
            if rlp.count == 9 {
                // make sure transaction isn't already signed
                guard rlp[7].isEmpty, rlp[8].isEmpty else {
                    return nil
                }
                networkId = UInt(bigEndianData: rlp[6])
                guard let networkIdValue = networkId else {
                    return nil
                }
                if networkIdValue == 0 {
                    networkId = nil
                    rlp.removeLast(3)
                }
            } else if rlp.count == 6 {
                networkId = nil
            } else {
                // bad length
                return nil
            }

            let signature = walletCereal.sign(hex: try RLP.encode(rlp).hexEncodedString())
            let sOffset = signature.index(signature.startIndex, offsetBy: 64)
            let vOffset = signature.index(signature.startIndex, offsetBy: 128)
            guard signature.count == 130,
                  let r = String(signature[..<sOffset]).hexadecimalData,
                  let s = String(signature[sOffset..<vOffset]).hexadecimalData,
                  let vData = String(signature[vOffset...]).hexadecimalData,
                  var v = UInt(bigEndianData: vData) else {
                return nil
            }

            if rlp.count == 9 {
                rlp.removeLast(3)
            }
            if let networkIdValue = networkId {
                v += 35 + networkIdValue * 2
            } else {
                v += 27
            }
            rlp.append(contentsOf: [Data(bigEndianFrom: v), r, s])

            let encodedSignedTransactionData = try RLP.encode(rlp)
            return "0x\(encodedSignedTransactionData.hexEncodedString())"
        } catch {
            return nil
        }
    }

    func sha3WithWallet(string: String) -> String {
        return walletCereal.sha3(string: string)
    }

    @objc private func userCreated(_ notification: Notification) {
        Yap.sharedInstance.insert(object: mnemonic.words.joined(separator: " "), for: Cereal.privateKeyStorageKey)
        UserDefaultsWrapper.hasStoredPassphraseInYap = true
    }
}

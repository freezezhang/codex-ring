import Foundation
import Security

enum SigningFingerprint {
    static func current()->String? {
        var running:SecCode?
        var code:SecStaticCode?
        var information:CFDictionary?
        let flags=SecCSFlags(rawValue:0)
        guard SecCodeCopySelf(flags,&running) == errSecSuccess,let running,
              SecCodeCopyStaticCode(running,flags,&code) == errSecSuccess,let code,
              SecCodeCopySigningInformation(code,flags,&information) == errSecSuccess,
              let values=information as? [String:Any],
              let hash=values[kSecCodeInfoUnique as String] as? Data,!hash.isEmpty else { return nil }
        return hash.map { String(format:"%02x",$0) }.joined()
    }
}

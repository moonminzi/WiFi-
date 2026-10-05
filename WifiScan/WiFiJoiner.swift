import NetworkExtension

enum WiFiJoiner {
    enum Outcome {
        case joined
        case cancelled
        case notConnected      // 시스템이 설정은 받았지만 실제 접속은 확인되지 않음(대개 비밀번호 오류나 신호 범위 밖)
        case failed(String)
    }

    static func join(ssid: String, password: String) async -> Outcome {
        let configuration = password.isEmpty
            ? NEHotspotConfiguration(ssid: ssid)
            : NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        configuration.joinOnce = false   // 설정 앱의 '알려진 네트워크'로 남겨서 다음에 자동 접속

        do {
            try await NEHotspotConfigurationManager.shared.apply(configuration)
        } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain {
            switch NEHotspotConfigurationError(rawValue: error.code) {
            case .alreadyAssociated: return .joined
            case .userDenied: return .cancelled
            case .invalidWPAPassphrase: return .failed("pw must be 8–63 chars")
            case .invalidSSID: return .failed("invalid ssid")
            default: return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }

        // apply()는 비밀번호가 틀려도 성공으로 끝나는 경우가 많아서, 실제로 붙었는지 확인한다.
        for _ in 0..<10 {
            if await NEHotspotNetwork.fetchCurrent()?.ssid == ssid { return .joined }
            try? await Task.sleep(for: .seconds(1))
        }
        // 잘못된 비밀번호가 '알려진 네트워크'로 남지 않도록 지운다.
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        return .notConnected
    }
}

/*
Backend configuration shared by networking services.
*/

import Foundation

enum BackendConfig {
    static let defaultBaseURL = "https://sheryl-biocellate-sympathizingly.ngrok-free.dev"

    static var baseURL: String {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String,
              !url.isEmpty else {
            return defaultBaseURL
        }
        return url
    }
}

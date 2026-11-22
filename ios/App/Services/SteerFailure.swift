import Foundation

/// Tells a failed steer apart from a steer that never reached the sidecar.
///
/// The composer is cleared before the sidecar answers, so a failed steer
/// has to decide whether the owner's text goes back into it.  A failure
/// that certainly happened before the request was delivered puts the text
/// back, and a failure that leaves the outcome unknown does not: the
/// sidecar may have injected the text, and an owner who finds it back in
/// the composer sends the same correction twice.
enum SteerFailure {
    /// True when the steer certainly never reached the sidecar.
    ///
    /// The failures that leave the outcome unknown are a timeout, a lost
    /// connection, a cancelled request, an answer that is not an HTTP
    /// response, and a response that could not be read.  Every other
    /// failure is read as one that happened before the request was
    /// delivered, because an error the client does not know comes from the
    /// code that built the request rather than from the sidecar.
    static func failedBeforeSend(_ error: Error) -> Bool {
        if let clientError = error as? ChatClientError {
            switch clientError {
            case .missingToken, .badHost, .steerRejected:
                // The request never left, or the sidecar answered and
                // refused, so it did not inject the text.
                return true
            case .http:
                // The answer was not an HTTP response, so nothing says what
                // the sidecar did with the request.
                return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cancelled:
                // The request may have reached the sidecar.
                return false
            case .cannotParseResponse, .cannotDecodeContentData:
                // The sidecar answered, so it may have injected the text.
                return false
            default:
                // Every other URL failure happened before the request was
                // delivered: no host, no route, no network, no TLS.
                return true
            }
        }
        return true
    }
}

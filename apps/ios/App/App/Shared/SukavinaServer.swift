import Foundation

/// The Sukavina server: the one place for the host that the app, the widget
/// and the Live Activity actions call (it was written out in six files).
enum SukavinaServer {
    /// "https://sukavinagroup.net", for site-relative paths such as images.
    static let origin = "https://sukavinagroup.net"
    /// The API root; request paths are relative to it.
    static let api = URL(string: origin + "/api/")!
}

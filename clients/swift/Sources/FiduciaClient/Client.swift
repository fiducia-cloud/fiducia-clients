import Foundation
public struct Client: Sendable {
  public let baseURL: URL
  public let bearerToken: String?
  public init(baseURL: URL, bearerToken: String? = nil) {
    self.baseURL = baseURL; self.bearerToken = bearerToken
  }
}

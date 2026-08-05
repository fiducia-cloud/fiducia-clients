final class FiduciaClient {
  const FiduciaClient({required this.baseUrl, this.bearerToken});
  final Uri baseUrl;
  final String? bearerToken;
}

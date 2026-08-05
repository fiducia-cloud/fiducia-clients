class FiduciaClient
  attr_reader :base_url, :bearer_token
  def initialize(base_url:, bearer_token: nil)
    @base_url = base_url
    @bearer_token = bearer_token
  end
end

import gleam/option.{type Option}
pub type Client { Client(base_url: String, bearer_token: Option(String)) }
pub fn new(base_url: String, bearer_token: Option(String)) -> Client {
  Client(base_url: base_url, bearer_token: bearer_token)
}

package fiduciaclient
import "net/url"
type Client struct { BaseURL *url.URL; BearerToken string }
func New(baseURL, bearerToken string) (*Client, error) {
    parsed, err := url.Parse(baseURL); if err != nil { return nil, err }
    return &Client{BaseURL: parsed, BearerToken: bearerToken}, nil
}

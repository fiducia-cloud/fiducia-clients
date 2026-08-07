export interface ClientOptions { baseUrl: string; bearerToken?: string }
export class Client {
  readonly baseUrl: URL;
  readonly bearerToken?: string;
  constructor(options: ClientOptions) {
    this.baseUrl = new URL(options.baseUrl);
    this.bearerToken = options.bearerToken;
  }
}

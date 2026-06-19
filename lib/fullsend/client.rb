require "net/http"
require "uri"
require "json"
require "openssl"
require "erb"

module Fullsend
  # HTTP client for the Fullsend service API. Distinct from the SQS-based
  # ActionMailer delivery path (Fullsend::Delivery): this makes synchronous
  # signed requests to the Fullsend HTTP API.
  #
  # Requests are authenticated with an HMAC signature over the request body
  # (empty string for bodyless verbs like DELETE), matching the service's
  # scheme:
  #
  #   Authorization: HMAC <hex(HMAC-SHA256(api_key, body))>
  #
  # Usage:
  #
  #   Fullsend::Client.new.delete_ses_suppression("user@example.com")
  #
  # Methods return a Fullsend::Client::Response. Transport-level failures
  # (timeouts, connection errors) raise Fullsend::ApiError.
  class Client
    HMAC_PREFIX = "HMAC".freeze
    SES_SUPPRESSIONS_PATH = "v1/ses-suppressions".freeze

    DEFAULT_OPEN_TIMEOUT = 2
    DEFAULT_READ_TIMEOUT = 5

    REQUEST_CLASSES = {
      get: Net::HTTP::Get,
      post: Net::HTTP::Post,
      put: Net::HTTP::Put,
      delete: Net::HTTP::Delete
    }.freeze

    # Lightweight wrapper around the HTTP response. Mirrors the platform's
    # ServiceHelper::Response shape (success?/not_found?/status_code/body)
    # so callers can treat an expected 404 (address not on the list) as a
    # normal outcome instead of an exception.
    class Response
      attr_reader :status_code, :body

      def initialize(status_code, body)
        @status_code = status_code
        @body = body
      end

      def success?
        (200..299).cover?(status_code)
      end

      def not_found?
        status_code == 404
      end

      # Parsed JSON body, or nil when the body is empty or not valid JSON
      # (a 204 with no content is normal for a successful DELETE).
      def data
        return nil if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
    end

    def initialize(configuration = Fullsend.configuration)
      @configuration = configuration
    end

    # DELETE /v1/ses-suppressions/:email
    #
    # Removes an address from the SES suppression list so the service can
    # deliver to it again. A 404 (address was not suppressed) is returned
    # as a non-raising Response — check `response.not_found?`.
    def delete_ses_suppression(email)
      request(:delete, "#{SES_SUPPRESSIONS_PATH}/#{ERB::Util.url_encode(email)}")
    end

    private

    def request(method, path, body: nil)
      @configuration.validate_api!

      payload = encode_body(body)
      uri = build_uri(path)
      req = REQUEST_CLASSES.fetch(method).new(uri)
      req["Content-Type"] = "application/json"
      req["Authorization"] = signature(payload)
      req.body = payload unless payload.empty?

      res = connection(uri).request(req)
      Response.new(res.code.to_i, res.body)
    rescue ConfigurationError
      raise
    rescue StandardError => e
      raise ApiError.new("Fullsend API request failed: #{e.class}: #{e.message}")
    end

    def encode_body(body)
      return "" if body.nil?
      return body if body.is_a?(String)

      body.to_json
    end

    def signature(payload)
      "#{HMAC_PREFIX} #{OpenSSL::HMAC.hexdigest("SHA256", @configuration.resolve_api_key, payload)}"
    end

    def build_uri(path)
      base = @configuration.resolve_api_base_url.to_s.sub(%r{/+\z}, "")
      URI.parse("#{base}/#{path}")
    end

    def connection(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = DEFAULT_OPEN_TIMEOUT
      http.read_timeout = DEFAULT_READ_TIMEOUT
      http
    end
  end
end

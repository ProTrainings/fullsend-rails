require "net/http"
require "uri"
require "json"
require "erb"

module Fullsend
  # HTTP client for the Fullsend service API. Distinct from the SQS-based
  # ActionMailer delivery path (Fullsend::Delivery): this makes synchronous
  # authenticated requests to the Fullsend HTTP API.
  #
  # Requests are authenticated with a bearer token, matching the service's
  # scheme:
  #
  #   Authorization: Bearer <api_token>
  #
  # Minting and refreshing that token is the host application's
  # responsibility; this client only forwards the configured value (see
  # Configuration#api_token, which accepts a callable for expiring tokens).
  #
  # Usage:
  #
  #   Fullsend::Client.new.delete_ses_suppression("user@example.com")
  #   Fullsend::Client.new.track_event("course.started", email: "joe@example.com")
  #
  # Methods return a Fullsend::Client::Response. Transport-level failures
  # (timeouts, connection errors) raise Fullsend::ApiError.
  class Client
    BEARER_PREFIX = "Bearer".freeze
    SES_SUPPRESSIONS_PATH = "v1/ses-suppressions".freeze
    EVENTS_PATH = "v1/events".freeze

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

    # The acknowledgement from the event intake. The service accepts an event
    # whose key is not in its registry rather than rejecting it — a registry
    # edit must not break an emitting app mid-deploy — so a 2xx alone does not
    # mean the event landed anywhere. `registered?` and `matched_campaigns`
    # are what tell you whether any automation listened.
    class EventResult < Response
      def self.from(response)
        new(response.status_code, response.body)
      end

      # False when the key is absent from the registry or archived. Still a
      # 2xx — worth logging in the emitting app, since a key landing nowhere
      # is otherwise invisible until someone notices an automation went quiet.
      def registered?
        result["registered"] == true
      end

      # Automations whose triggers matched this event.
      def matched_campaigns
        result["matched_campaigns"].to_i
      end

      # Runs this event opened, advanced, and ended, respectively.
      def enrolled
        result["enrolled"].to_i
      end

      def signalled
        result["signalled"].to_i
      end

      def stopped
        result["stopped"].to_i
      end

      private

      # Parsed once — every reader above reads it.
      def result
        return @result if defined?(@result)

        parsed = data
        @result = parsed.is_a?(Hash) ? parsed : {}
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

    # POST /v1/events
    #
    # Reports a domain fact ("this happened") to the event intake. The call is
    # not scoped to any automation — the emitting app does not need to know
    # which automations exist, and every automation whose triggers listen for
    # the key decides for itself what to do with the event. The same key can
    # open a run in one automation and end a run in another.
    #
    #   Fullsend::Client.new.track_event(
    #     "course.started",
    #     email: user.email,
    #     subject_id: "u_#{user.id}",
    #     properties: { course_id: course.id, course_name: course.name }
    #   )
    #
    # `properties` becomes the run's data context on enroll, so condition
    # nodes downstream can read it by dot path (e.g. "user.first_name"). Keep
    # it to JSON-serializable values.
    #
    # `app_id` defaults to the configured fullsend_app_id. Returns an
    # EventResult; an unregistered key is a 2xx with `registered?` false.
    def track_event(event_key, email:, subject_id: nil, properties: nil, app_id: nil)
      EventResult.from(
        request(:post, EVENTS_PATH, body: event_payload(event_key, email, subject_id, properties, app_id))
      )
    end

    private

    # Mirrors the service's own required fields. Checked here so a missing
    # value fails at the call site with the offending field named, rather
    # than as an opaque 400 from a background job.
    def event_payload(event_key, email, subject_id, properties, app_id)
      resolved_app_id = blank?(app_id) ? @configuration.fullsend_app_id : app_id
      if blank?(resolved_app_id)
        raise ConfigurationError,
          "app_id is required to track an event. Set fullsend_app_id via Fullsend.configure or pass app_id:."
      end
      raise ArgumentError, "event_key is required to track an event" if blank?(event_key)
      raise ArgumentError, "email is required to track an event" if blank?(email)

      payload = { app_id: resolved_app_id.to_s, event_key: event_key.to_s, email: email.to_s }
      payload[:subject_id] = subject_id.to_s unless blank?(subject_id)
      payload[:properties] = properties if properties.is_a?(Hash) && !properties.empty?
      payload
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def request(method, path, body: nil)
      @configuration.validate_api!

      payload = encode_body(body)
      uri = build_uri(path)
      req = REQUEST_CLASSES.fetch(method).new(uri)
      req["Content-Type"] = "application/json"
      req["Authorization"] = authorization
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

    # Resolved per request so a callable api_token picks up a token the host
    # application refreshed since the last call.
    def authorization
      token = @configuration.resolve_api_token.to_s
      if token.empty?
        raise ConfigurationError,
          "api_token resolved to an empty value for Fullsend::Client. Check Fullsend.configure or FULLSEND_API_TOKEN."
      end

      "#{BEARER_PREFIX} #{token}"
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

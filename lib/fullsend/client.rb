require "net/http"
require "uri"
require "json"
require "erb"
require "time"

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
  #   Fullsend::Client.new.drip_enrollments("joe@example.com")
  #
  # Methods return a Fullsend::Client::Response. Transport-level failures
  # (timeouts, connection errors) raise Fullsend::ApiError.
  class Client
    BEARER_PREFIX = "Bearer".freeze
    SES_SUPPRESSIONS_PATH = "v1/ses-suppressions".freeze
    EVENTS_PATH = "v1/events".freeze
    DRIP_ENROLLMENTS_PATH = "v1/drip-campaigns/enrollments".freeze

    # Enrollment statuses the service recognizes. Checked before the request so
    # a typo names itself here rather than coming back as an opaque 400.
    DRIP_STATUSES = %w[active waiting completed stopped].freeze

    # Pass as `app_id:` to search every app the token can see instead of the
    # configured one. Only useful for an admin or support tool — an app asking
    # about its own recipients wants the default scoping.
    ALL_APPS = :all

    # The service falls back to its default page size (silently) when asked for
    # more than its maximum, so the bound is enforced here instead.
    DRIP_MAX_PAGE_SIZE = 500

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

    # One row from #drip_enrollments: a recipient's enrollment in a campaign,
    # carrying the campaign's name and id so naming it takes no second call.
    #
    # Readers cover the fields worth asking about; #[] and #to_h reach anything
    # else the service returns.
    class Enrollment
      # An enrollment is still live while it is active OR waiting: a 'waiting'
      # run is merely parked on a branch condition and is still enrolled. The
      # service derives `active` with this same rule; this constant only backs
      # the fallback in #active? for a response that predates the field.
      LIVE_STATUSES = %w[active waiting].freeze

      attr_reader :attributes

      def initialize(attributes)
        @attributes = attributes.is_a?(Hash) ? attributes : {}
      end

      def id
        attributes["id"]
      end

      def email
        attributes["email"].to_s
      end

      def app_id
        attributes["app_id"].to_s
      end

      # The campaign's own string identifier (its tag), which is what a
      # campaign is referred to by outside the service.
      def campaign_id
        attributes["campaign_id"].to_s
      end

      # The campaign's numeric primary key, as used in /v1/drip-campaigns/:id.
      def drip_campaign_id
        attributes["drip_campaign_id"]
      end

      def campaign_name
        attributes["campaign_name"].to_s
      end

      # active | waiting | completed | stopped. Prefer #active? over comparing
      # this to "active" — see LIVE_STATUSES.
      def status
        attributes["status"].to_s
      end

      def active?
        return attributes["active"] == true if attributes.key?("active")

        LIVE_STATUSES.include?(status)
      end

      # True when the campaign has since been soft-deleted. Such enrollments are
      # still returned — the row is real history, the person was enrolled.
      def campaign_deleted?
        attributes["campaign_deleted"] == true
      end

      # Why a stopped enrollment stopped (e.g. "conversion", "manual",
      # "bounce"). Empty for enrollments that were not stopped.
      def stop_reason
        attributes["stop_reason"].to_s
      end

      # The emitting app's own id for the person, when the event that enrolled
      # them carried one.
      def subject_id
        attributes["subject_id"].to_s
      end

      # Scopes concurrent runs of the same campaign for one recipient (e.g. one
      # run per course).
      def correlation_key
        attributes["correlation_key"].to_s
      end

      # The run's data payload — the event `properties` it was enrolled with.
      def context
        value = attributes["context"]
        value.is_a?(Hash) ? value : {}
      end

      def current_node_id
        attributes["current_node_id"].to_s
      end

      def enrolled_at
        time("enrolled_at")
      end

      def completed_at
        time("completed_at")
      end

      def stopped_at
        time("stopped_at")
      end

      def [](key)
        attributes[key.to_s]
      end

      def to_h
        attributes
      end

      private

      def time(key)
        raw = attributes[key]
        return nil if raw.nil? || raw.to_s.empty?

        Time.parse(raw.to_s)
      rescue ArgumentError
        nil
      end
    end

    # The answer to "which campaigns is this address in". Rows come back newest
    # enrollment first, in every state unless the call filtered them.
    class DripEnrollmentsResult < Response
      def self.from(response)
        new(response.status_code, response.body)
      end

      # Array<Enrollment>. Empty for a non-2xx, so check #success? first when
      # an empty list and a failed call need telling apart.
      def enrollments
        return @enrollments if defined?(@enrollments)

        rows = result["enrollments"]
        @enrollments = (rows.is_a?(Array) ? rows : []).map { |row| Enrollment.new(row) }
      end

      # Just the live ones (active or waiting) — the usual question.
      def active
        enrollments.select(&:active?)
      end

      # Is the recipient currently in this campaign? Takes either the campaign's
      # string id (its tag) or its numeric id.
      def active_in?(campaign)
        active.any? { |enrollment| matches?(enrollment, campaign) }
      end

      # Have they ever been in it, finished and stopped runs included?
      def enrolled_in?(campaign)
        enrollments.any? { |enrollment| matches?(enrollment, campaign) }
      end

      # Names of the campaigns they are currently in, for a support screen or a
      # log line. Deduplicated: a campaign can hold more than one live run.
      def active_campaign_names
        active.map(&:campaign_name).uniq
      end

      def size
        enrollments.size
      end

      def any?
        !enrollments.empty?
      end

      def empty?
        enrollments.empty?
      end

      private

      def matches?(enrollment, campaign)
        return enrollment.drip_campaign_id == campaign if campaign.is_a?(Integer)

        enrollment.campaign_id == campaign.to_s
      end

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

    # GET /v1/drip-campaigns/enrollments
    #
    # Which automations is this address enrolled in? One call covers every
    # campaign and every state, so a support screen or a guard ("don't enroll
    # them twice") does not need a request per campaign.
    #
    #   result = Fullsend::Client.new.drip_enrollments("joe@example.com")
    #   result.active_campaign_names        # => ["Trial nurture"]
    #   result.active_in?("trial-nurture")  # => true
    #
    # By default only the configured `fullsend_app_id` is searched; pass
    # `app_id: Fullsend::Client::ALL_APPS` for every app the token can see, or
    # an explicit id for another one. When no app_id is configured or given the
    # search is not app-scoped.
    #
    # Filters:
    #   active:    true  => live runs only (status active OR waiting)
    #              false => finished runs only (completed/stopped)
    #              nil   => every state (the default)
    #   status:    one exact status, for drilling into a single state. Prefer
    #              `active: true` for "still enrolled" — `status: "active"`
    #              omits every run parked on a branch condition.
    #   page_size: newest-first cap, default 100, max DRIP_MAX_PAGE_SIZE.
    #
    # The address is matched exactly, as stored. Returns a
    # DripEnrollmentsResult; a non-2xx does not raise.
    def drip_enrollments(email, app_id: nil, active: nil, status: nil, page_size: nil)
      DripEnrollmentsResult.from(
        request(:get, DRIP_ENROLLMENTS_PATH, query: drip_enrollments_query(email, app_id, active, status, page_size))
      )
    end

    private

    # Validated here so a bad filter fails at the call site with the offending
    # field named, rather than as an opaque 400 — or, for an oversized
    # page_size, as a silently smaller page.
    def drip_enrollments_query(email, app_id, active, status, page_size)
      raise ArgumentError, "email is required to look up drip enrollments" if blank?(email)

      query = { email: email.to_s }

      resolved_app_id = resolve_drip_app_id(app_id)
      query[:app_id] = resolved_app_id.to_s unless resolved_app_id.nil?

      unless active.nil?
        query[:active] = active ? "true" : "false"
      end

      unless blank?(status)
        unless DRIP_STATUSES.include?(status.to_s)
          raise ArgumentError, "unknown drip enrollment status #{status.inspect}. One of: #{DRIP_STATUSES.join(", ")}"
        end

        query[:status] = status.to_s
      end

      unless page_size.nil?
        size = page_size.to_i
        unless (1..DRIP_MAX_PAGE_SIZE).cover?(size)
          raise ArgumentError, "page_size must be between 1 and #{DRIP_MAX_PAGE_SIZE}, got #{page_size.inspect}"
        end

        query[:page_size] = size
      end

      query
    end

    # nil means "the app this gem is configured for", which is what a host app
    # asking about its own recipients wants. ALL_APPS opts out of the scoping;
    # so does having no fullsend_app_id configured, since the service treats a
    # missing app_id as "every app" and there is nothing to narrow to.
    def resolve_drip_app_id(app_id)
      return nil if app_id == ALL_APPS

      candidate = blank?(app_id) ? @configuration.fullsend_app_id : app_id
      blank?(candidate) ? nil : candidate
    end

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

    def request(method, path, body: nil, query: nil)
      @configuration.validate_api!

      payload = encode_body(body)
      uri = build_uri(path, query)
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

    def build_uri(path, query = nil)
      base = @configuration.resolve_api_base_url.to_s.sub(%r{/+\z}, "")
      uri = URI.parse("#{base}/#{path}")
      uri.query = URI.encode_www_form(query) unless query.nil? || query.empty?
      uri
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

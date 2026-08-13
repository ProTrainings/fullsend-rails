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
    UNSUBSCRIBES_PATH = "v1/unsubscribes".freeze

    # How wide an opt-out reaches. SCOPE_CAMPAIGN silences one automation and
    # leaves the rest; SCOPE_APP is "stop emailing me from this app at all".
    SCOPE_CAMPAIGN = "campaign".freeze
    SCOPE_APP = "app".freeze
    UNSUBSCRIBE_SCOPES = [SCOPE_CAMPAIGN, SCOPE_APP].freeze

    # How the opt-out was collected, which is what a compliance question asks
    # about later. ONE_CLICK is an RFC 8058 List-Unsubscribe POST, LINK_CLICK a
    # footer link, MANUAL a preferences page or a support agent.
    REASON_ONE_CLICK = "one_click".freeze
    REASON_LINK_CLICK = "link_click".freeze
    REASON_MANUAL = "manual".freeze
    UNSUBSCRIBE_REASONS = [REASON_ONE_CLICK, REASON_LINK_CLICK, REASON_MANUAL].freeze

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

    # One opt-out row. Unlike stopping an enrollment — which ends the runs
    # already open and nothing more — this row is what keeps the address out of
    # the *next* enrollment too, and the service also re-checks it at send time,
    # so it silences the runs already in flight. It is what an unsubscribe
    # actually is.
    class Unsubscribe
      attr_reader :attributes

      def initialize(attributes)
        @attributes = attributes.is_a?(Hash) ? attributes : {}
      end

      # The row id — what DELETE /v1/unsubscribes/:id takes to re-subscribe.
      def id
        attributes["id"]
      end

      def email
        attributes["email"].to_s
      end

      def app_id
        attributes["app_id"].to_s
      end

      # The campaign's string id (its tag). Empty for an app-scoped opt-out.
      def campaign_id
        attributes["campaign_id"].to_s
      end

      # "campaign" | "app". Comes back resolved, so this is the scope that was
      # actually stored rather than the one asked for.
      def scope
        attributes["scope"].to_s
      end

      def reason
        attributes["reason"].to_s
      end

      # True for "stop emailing me from this app at all". An app-wide row
      # suppresses every campaign, so it outranks any campaign-scoped row.
      def app_wide?
        scope == SCOPE_APP
      end

      def created_at
        raw = attributes["created_at"]
        return nil if raw.nil? || raw.to_s.empty?

        Time.parse(raw.to_s)
      rescue ArgumentError
        nil
      end

      def [](key)
        attributes[key.to_s]
      end

      def to_h
        attributes
      end
    end

    # The opt-out record the service stored, echoed back. Readers are delegated
    # to the Unsubscribe row so a created record and a listed one read alike.
    class UnsubscribeResult < Response
      def self.from(response)
        new(response.status_code, response.body)
      end

      # The stored row. Readers below cover it; reach #attributes for anything
      # the service returns that has no reader.
      def unsubscribe
        return @unsubscribe if defined?(@unsubscribe)

        parsed = data
        @unsubscribe = Unsubscribe.new(parsed.is_a?(Hash) ? parsed : {})
      end

      def id
        unsubscribe.id
      end

      def email
        unsubscribe.email
      end

      def app_id
        unsubscribe.app_id
      end

      def campaign_id
        unsubscribe.campaign_id
      end

      def scope
        unsubscribe.scope
      end

      def reason
        unsubscribe.reason
      end

      def app_wide?
        unsubscribe.app_wide?
      end

      def created_at
        unsubscribe.created_at
      end
    end

    # Which opt-outs are on file for an address — what a preferences page needs
    # to render current state, since an enrollment stays live (merely silenced)
    # after someone opts out and so still comes back from #drip_enrollments.
    class UnsubscribesResult < Response
      def self.from(response)
        new(response.status_code, response.body)
      end

      # Array<Unsubscribe>. Empty for a non-2xx, so check #success? when an
      # empty list and a failed call need telling apart.
      def unsubscribes
        return @unsubscribes if defined?(@unsubscribes)

        rows = result["unsubscribes"]
        @unsubscribes = (rows.is_a?(Array) ? rows : []).map { |row| Unsubscribe.new(row) }
      end

      # Opaque cursor for the next page, when the service returned one.
      def next_token
        result["next_token"].to_s
      end

      # True when an app-wide opt-out is on file — "stop emailing me at all",
      # which suppresses every campaign regardless of campaign-scoped rows.
      def app_wide?
        unsubscribes.any?(&:app_wide?)
      end

      # The app-wide row itself, for re-subscribing (its id is what DELETE
      # takes). Nil when there is none.
      def app_wide
        unsubscribes.detect(&:app_wide?)
      end

      # Campaign tags with a campaign-scoped opt-out. Deliberately does *not*
      # fold in an app-wide row: those are different states a preferences page
      # renders differently, and #suppressed? is the question that merges them.
      def campaign_ids
        unsubscribes.reject(&:app_wide?).map(&:campaign_id).uniq
      end

      # The campaign-scoped row for a tag, or nil. Its id is what re-subscribing
      # takes.
      def for_campaign(campaign_id)
        unsubscribes.detect { |row| !row.app_wide? && row.campaign_id == campaign_id.to_s }
      end

      # Would the service refuse to send this campaign to them? Matches the
      # service's own rule: an app-wide opt-out, or a campaign-scoped one for
      # this tag.
      def suppressed?(campaign_id)
        app_wide? || !for_campaign(campaign_id).nil?
      end

      def size
        unsubscribes.size
      end

      def any?
        !unsubscribes.empty?
      end

      def empty?
        unsubscribes.empty?
      end

      private

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

    # POST /v1/unsubscribes
    #
    # Records that an address opted out. This is the durable half of an
    # unsubscribe: stopping an enrollment ends the runs already open, but only
    # an opt-out row keeps the next matching event from enrolling them again.
    # A preferences page wants this; it may also want to stop the live runs so
    # the current sequence goes quiet immediately.
    #
    #   Fullsend::Client.new.create_unsubscribe(
    #     user.email,
    #     scope: Fullsend::Client::SCOPE_CAMPAIGN,
    #     campaign_id: "trial-nurture",
    #     reason: Fullsend::Client::REASON_MANUAL
    #   )
    #
    # `scope` has deliberately no default. The service defaults a missing scope
    # to app-wide, and silently opting someone out of every campaign because a
    # keyword was forgotten is not a failure mode worth keeping — so name it.
    # SCOPE_CAMPAIGN requires `campaign_id` (the campaign's string id, which is
    # what Enrollment#campaign_id returns).
    #
    # `reason` defaults to the service's own default (manual) when omitted.
    # `app_id` defaults to the configured fullsend_app_id.
    #
    # Returns an UnsubscribeResult; a non-2xx does not raise, so check
    # `#success?`.
    def create_unsubscribe(email, scope:, campaign_id: nil, reason: nil, app_id: nil)
      UnsubscribeResult.from(
        request(:post, UNSUBSCRIBES_PATH, body: unsubscribe_payload(email, scope, campaign_id, reason, app_id))
      )
    end

    # GET /v1/unsubscribes
    #
    # Which opt-outs are on file. A preferences page needs this to render
    # current state: opting out does not end the enrollment, only silences it,
    # so #drip_enrollments keeps returning a campaign someone already left.
    #
    #   result = Fullsend::Client.new.unsubscribes("joe@example.com")
    #   result.app_wide?                    # => false
    #   result.suppressed?("trial-nurture") # => true
    #
    # `app_id` defaults to the configured fullsend_app_id; pass ALL_APPS to opt
    # out of that scoping. `scope` narrows to one kind of row — usually you want
    # both, since an app-wide row suppresses campaigns too.
    #
    # Returns an UnsubscribesResult; a non-2xx does not raise.
    def unsubscribes(email = nil, app_id: nil, scope: nil, page_size: nil)
      UnsubscribesResult.from(
        request(:get, UNSUBSCRIBES_PATH, query: unsubscribes_query(email, app_id, scope, page_size))
      )
    end

    # DELETE /v1/unsubscribes/:id
    #
    # Removes an opt-out row — re-subscribing the address. Takes the row id from
    # Unsubscribe#id (UnsubscribesResult#for_campaign / #app_wide are how a
    # preferences page finds the one to remove).
    #
    # Note this only clears the local marketing opt-out. An address SES itself
    # suppressed after a hard bounce or complaint stays suppressed — see
    # #delete_ses_suppression for that list.
    def delete_unsubscribe(id)
      raise ArgumentError, "id is required to delete an unsubscribe" if blank?(id)

      request(:delete, "#{UNSUBSCRIBES_PATH}/#{ERB::Util.url_encode(id)}")
    end

    private

    def unsubscribes_query(email, app_id, scope, page_size)
      query = {}
      query[:email] = email.to_s unless blank?(email)

      resolved_app_id = resolve_drip_app_id(app_id)
      query[:app_id] = resolved_app_id.to_s unless resolved_app_id.nil?

      unless blank?(scope)
        unless UNSUBSCRIBE_SCOPES.include?(scope.to_s)
          raise ArgumentError, "unknown unsubscribe scope #{scope.inspect}. One of: #{UNSUBSCRIBE_SCOPES.join(", ")}"
        end

        query[:scope] = scope.to_s
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

    # Mirrors the service's own validation so a bad call names the offending
    # field here rather than coming back as an opaque 400 — and, for scope,
    # so an omitted campaign_id cannot quietly widen into an app-wide opt-out.
    def unsubscribe_payload(email, scope, campaign_id, reason, app_id)
      raise ArgumentError, "email is required to create an unsubscribe" if blank?(email)

      resolved_app_id = blank?(app_id) ? @configuration.fullsend_app_id : app_id
      if blank?(resolved_app_id)
        raise ConfigurationError,
          "app_id is required to create an unsubscribe. Set fullsend_app_id via Fullsend.configure or pass app_id:."
      end

      unless UNSUBSCRIBE_SCOPES.include?(scope.to_s)
        raise ArgumentError, "unknown unsubscribe scope #{scope.inspect}. One of: #{UNSUBSCRIBE_SCOPES.join(", ")}"
      end

      if scope.to_s == SCOPE_CAMPAIGN && blank?(campaign_id)
        raise ArgumentError, "campaign_id is required when scope is #{SCOPE_CAMPAIGN.inspect}"
      end

      unless blank?(reason) || UNSUBSCRIBE_REASONS.include?(reason.to_s)
        raise ArgumentError, "unknown unsubscribe reason #{reason.inspect}. One of: #{UNSUBSCRIBE_REASONS.join(", ")}"
      end

      payload = { email: email.to_s, app_id: resolved_app_id.to_s, scope: scope.to_s }
      payload[:campaign_id] = campaign_id.to_s unless blank?(campaign_id)
      payload[:reason] = reason.to_s unless blank?(reason)
      payload
    end

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

require "spec_helper"

RSpec.describe Fullsend::Client do
  let(:api_token) { "test-token" }
  let(:base_url) { "https://api.fullsend.example" }

  let(:http) { instance_double(Net::HTTP) }
  let(:captured) { [] }

  around do |example|
    original_env = ENV.to_hash
    ENV.delete("FULLSEND_API_URL")
    ENV.delete("FULLSEND_API_TOKEN")
    example.run
  ensure
    ENV.replace(original_env)
  end

  before do
    Fullsend.configure do |c|
      c.api_base_url = base_url
      c.api_token = api_token
    end

    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request) do |req|
      captured << req
      stub_response
    end
  end

  # A 204 No Content is the typical success for a DELETE.
  let(:stub_response) { double("response", code: "204", body: "") }

  def last_request
    captured.last
  end

  describe "#delete_ses_suppression" do
    it "issues a DELETE to the url-encoded suppression path" do
      described_class.new.delete_ses_suppression("user@example.com")

      expect(last_request).to be_a(Net::HTTP::Delete)
      expect(last_request.path).to eq("/v1/ses-suppressions/user%40example.com")
    end

    it "sends the api_token as a bearer token" do
      described_class.new.delete_ses_suppression("user@example.com")

      expect(last_request["Authorization"]).to eq("Bearer test-token")
    end

    it "url-encodes addresses with reserved characters" do
      described_class.new.delete_ses_suppression("a+b@example.com")

      expect(last_request.path).to eq("/v1/ses-suppressions/a%2Bb%40example.com")
    end

    it "does not send a request body for DELETE" do
      described_class.new.delete_ses_suppression("user@example.com")

      expect(last_request.body).to be_nil
    end

    it "returns a successful Response for a 2xx" do
      response = described_class.new.delete_ses_suppression("user@example.com")

      expect(response.success?).to be(true)
      expect(response.status_code).to eq(204)
    end

    it "returns a non-raising not_found Response when the address was not suppressed" do
      allow(http).to receive(:request).and_return(double("response", code: "404", body: ""))

      response = described_class.new.delete_ses_suppression("user@example.com")

      expect(response.success?).to be(false)
      expect(response.not_found?).to be(true)
    end

    it "wraps transport-level failures in Fullsend::ApiError" do
      allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)

      expect { described_class.new.delete_ses_suppression("user@example.com") }
        .to raise_error(Fullsend::ApiError)
    end
  end

  describe "#create_ses_suppression" do
    let(:stub_response) { double("response", code: "201", body: "") }

    it "POSTs the address and reason to the suppression collection" do
      described_class.new.create_ses_suppression(
        "user@example.com",
        reason: described_class::SES_SUPPRESSION_REASON_COMPLAINT
      )

      expect(last_request).to be_a(Net::HTTP::Post)
      expect(last_request.path).to eq("/v1/ses-suppressions")
      expect(JSON.parse(last_request.body)).to eq("email" => "user@example.com", "reason" => "COMPLAINT")
    end

    it "includes the source when one is given" do
      described_class.new.create_ses_suppression(
        "user@example.com",
        reason: described_class::SES_SUPPRESSION_REASON_BOUNCE,
        source: described_class::SES_SUPPRESSION_SOURCE_SPARKPOST
      )

      expect(JSON.parse(last_request.body)["source"]).to eq("sparkpost")
    end

    it "omits the source rather than sending an empty one" do
      described_class.new.create_ses_suppression(
        "user@example.com",
        reason: described_class::SES_SUPPRESSION_REASON_BOUNCE,
        source: ""
      )

      expect(JSON.parse(last_request.body)).not_to have_key("source")
    end

    it "sends the api_token as a bearer token" do
      described_class.new.create_ses_suppression(
        "user@example.com",
        reason: described_class::SES_SUPPRESSION_REASON_BOUNCE
      )

      expect(last_request["Authorization"]).to eq("Bearer test-token")
    end

    it "returns a successful Response for a 2xx" do
      response = described_class.new.create_ses_suppression(
        "user@example.com",
        reason: described_class::SES_SUPPRESSION_REASON_BOUNCE
      )

      expect(response.success?).to be(true)
      expect(response.status_code).to eq(201)
    end

    # Named at the call site rather than coming back as an opaque 400, the same
    # way an unknown unsubscribe scope is.
    it "raises on a reason the service does not recognize" do
      expect {
        described_class.new.create_ses_suppression("user@example.com", reason: "VALIDATION")
      }.to raise_error(ArgumentError, /unknown SES suppression reason/)
    end

    it "raises when the address is missing" do
      expect {
        described_class.new.create_ses_suppression("", reason: described_class::SES_SUPPRESSION_REASON_BOUNCE)
      }.to raise_error(ArgumentError, /email is required/)
    end

    it "does not issue a request when validation fails" do
      begin
        described_class.new.create_ses_suppression("", reason: described_class::SES_SUPPRESSION_REASON_BOUNCE)
      rescue ArgumentError
        nil
      end

      expect(captured).to be_empty
    end

    it "wraps transport-level failures in Fullsend::ApiError" do
      allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)

      expect {
        described_class.new.create_ses_suppression(
          "user@example.com",
          reason: described_class::SES_SUPPRESSION_REASON_BOUNCE
        )
      }.to raise_error(Fullsend::ApiError)
    end
  end

  describe "#track_event" do
    let(:stub_response) do
      double("response", code: "200", body: {
        event_key: "course.started", registered: true, matched_campaigns: 2,
        enrolled: 1, signalled: 1, stopped: 0
      }.to_json)
    end

    before { Fullsend.configure { |c| c.fullsend_app_id = "3163870b-4658-4d36-8a0d-e5c9d361800f" } }

    def payload
      JSON.parse(last_request.body)
    end

    it "POSTs to the events path" do
      described_class.new.track_event("course.started", email: "joe@gmail.com")

      expect(last_request).to be_a(Net::HTTP::Post)
      expect(last_request.path).to eq("/v1/events")
      expect(last_request["Authorization"]).to eq("Bearer test-token")
      expect(last_request["Content-Type"]).to eq("application/json")
    end

    it "sends the documented payload shape" do
      described_class.new.track_event(
        "course.started",
        email: "joe@gmail.com",
        subject_id: "u_12345",
        properties: { course_id: 2, course_name: "Course Two", user: { first_name: "John", last_name: "Doe" } }
      )

      expect(payload).to eq(
        "app_id" => "3163870b-4658-4d36-8a0d-e5c9d361800f",
        "event_key" => "course.started",
        "subject_id" => "u_12345",
        "email" => "joe@gmail.com",
        "properties" => {
          "course_id" => 2,
          "course_name" => "Course Two",
          "user" => { "first_name" => "John", "last_name" => "Doe" }
        }
      )
    end

    it "defaults app_id to the configured fullsend_app_id" do
      described_class.new.track_event("course.started", email: "joe@gmail.com")

      expect(payload["app_id"]).to eq("3163870b-4658-4d36-8a0d-e5c9d361800f")
    end

    it "lets an explicit app_id override the configured one" do
      described_class.new.track_event("course.started", email: "joe@gmail.com", app_id: "other-app")

      expect(payload["app_id"]).to eq("other-app")
    end

    # The service treats them as absent either way; omitting keeps the payload
    # matching the documented shape.
    it "omits subject_id and properties when not given" do
      described_class.new.track_event("course.started", email: "joe@gmail.com")

      expect(payload.keys).to contain_exactly("app_id", "event_key", "email")
    end

    it "omits properties when given an empty hash" do
      described_class.new.track_event("course.started", email: "joe@gmail.com", properties: {})

      expect(payload).not_to have_key("properties")
    end

    it "exposes the intake acknowledgement" do
      result = described_class.new.track_event("course.started", email: "joe@gmail.com")

      expect(result.success?).to be(true)
      expect(result.registered?).to be(true)
      expect(result.matched_campaigns).to eq(2)
      expect(result.enrolled).to eq(1)
      expect(result.signalled).to eq(1)
      expect(result.stopped).to eq(0)
    end

    # An unregistered key is accepted by design so a registry edit cannot break
    # an emitting app mid-deploy — the caller has to read `registered?` to know.
    it "reports registered? false for a key not in the registry" do
      allow(http).to receive(:request).and_return(
        double("response", code: "200", body: { event_key: "nope", registered: false }.to_json)
      )

      result = described_class.new.track_event("nope", email: "joe@gmail.com")

      expect(result.success?).to be(true)
      expect(result.registered?).to be(false)
      expect(result.matched_campaigns).to eq(0)
    end

    it "does not raise on a non-2xx" do
      allow(http).to receive(:request).and_return(double("response", code: "400", body: "\"email is required\""))

      result = described_class.new.track_event("course.started", email: "joe@gmail.com")

      expect(result.success?).to be(false)
      expect(result.status_code).to eq(400)
    end

    it "wraps transport-level failures in Fullsend::ApiError" do
      allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)

      expect { described_class.new.track_event("course.started", email: "joe@gmail.com") }
        .to raise_error(Fullsend::ApiError)
    end

    describe "required fields" do
      it "raises ConfigurationError when no app_id is configured or given" do
        Fullsend.configure { |c| c.fullsend_app_id = nil }

        expect { described_class.new.track_event("course.started", email: "joe@gmail.com") }
          .to raise_error(Fullsend::ConfigurationError, /app_id/)
      end

      it "raises ArgumentError for a blank event_key" do
        expect { described_class.new.track_event("  ", email: "joe@gmail.com") }
          .to raise_error(ArgumentError, /event_key/)
      end

      it "raises ArgumentError for a blank email" do
        expect { described_class.new.track_event("course.started", email: nil) }
          .to raise_error(ArgumentError, /email/)
      end

      it "does not issue a request when a required field is missing" do
        expect { described_class.new.track_event("course.started", email: nil) }.to raise_error(ArgumentError)
        expect(captured).to be_empty
      end
    end
  end

  describe "#drip_enrollments" do
    let(:app_id) { "3163870b-4658-4d36-8a0d-e5c9d361800f" }

    let(:rows) do
      [
        {
          id: 91, drip_campaign_id: 4, campaign_id: "trial-nurture", topic_key: "nurture",
          campaign_name: "Trial nurture", app_id: app_id, email: "joe@gmail.com",
          status: "waiting", active: true, campaign_deleted: false,
          current_node_id: "branch-1", subject_id: "u_12345",
          correlation_key: "course:2", context: { course_id: 2 },
          stop_reason: "", enrolled_at: "2026-08-01T10:00:00Z", version: 3
        },
        {
          id: 42, drip_campaign_id: 7, campaign_id: "onboarding",
          campaign_name: "Onboarding", app_id: app_id, email: "joe@gmail.com",
          status: "stopped", active: false, campaign_deleted: true,
          stop_reason: "conversion", enrolled_at: "2026-07-01T10:00:00Z",
          stopped_at: "2026-07-09T12:30:00Z"
        }
      ]
    end

    let(:stub_response) { double("response", code: "200", body: { enrollments: rows }.to_json) }

    before { Fullsend.configure { |c| c.fullsend_app_id = app_id } }

    def query
      URI.decode_www_form(URI.parse(last_request.path).query.to_s).to_h
    end

    it "GETs the enrollments path with the email as a query param" do
      described_class.new.drip_enrollments("joe@gmail.com")

      expect(last_request).to be_a(Net::HTTP::Get)
      expect(URI.parse(last_request.path).path).to eq("/v1/drip-campaigns/enrollments")
      expect(query).to include("email" => "joe@gmail.com")
      expect(last_request["Authorization"]).to eq("Bearer test-token")
    end

    it "url-encodes the address" do
      described_class.new.drip_enrollments("a+b@example.com")

      expect(last_request.path).to include("email=a%2Bb%40example.com")
      expect(query["email"]).to eq("a+b@example.com")
    end

    it "does not send a request body" do
      described_class.new.drip_enrollments("joe@gmail.com")

      expect(last_request.body).to be_nil
    end

    describe "app scoping" do
      it "scopes to the configured fullsend_app_id by default" do
        described_class.new.drip_enrollments("joe@gmail.com")

        expect(query["app_id"]).to eq(app_id)
      end

      it "lets an explicit app_id override the configured one" do
        described_class.new.drip_enrollments("joe@gmail.com", app_id: "other-app")

        expect(query["app_id"]).to eq("other-app")
      end

      it "omits app_id for ALL_APPS" do
        described_class.new.drip_enrollments("joe@gmail.com", app_id: Fullsend::Client::ALL_APPS)

        expect(query).not_to have_key("app_id")
      end

      # The service treats a missing app_id as every app, and there is nothing
      # to narrow to, so this is not an error the way it is for track_event.
      it "omits app_id when none is configured or given" do
        Fullsend.configure { |c| c.fullsend_app_id = nil }

        described_class.new.drip_enrollments("joe@gmail.com")

        expect(query).not_to have_key("app_id")
      end
    end

    describe "filters" do
      it "sends no filters by default, so every state comes back" do
        described_class.new.drip_enrollments("joe@gmail.com")

        expect(query.keys).to contain_exactly("email", "app_id")
      end

      it "sends active=true for live runs only" do
        described_class.new.drip_enrollments("joe@gmail.com", active: true)

        expect(query["active"]).to eq("true")
      end

      it "sends active=false for finished runs only" do
        described_class.new.drip_enrollments("joe@gmail.com", active: false)

        expect(query["active"]).to eq("false")
      end

      it "sends an exact status" do
        described_class.new.drip_enrollments("joe@gmail.com", status: "completed")

        expect(query["status"]).to eq("completed")
      end

      it "sends page_size" do
        described_class.new.drip_enrollments("joe@gmail.com", page_size: 25)

        expect(query["page_size"]).to eq("25")
      end
    end

    describe "argument validation" do
      it "raises ArgumentError for a blank email" do
        expect { described_class.new.drip_enrollments("  ") }
          .to raise_error(ArgumentError, /email/)
      end

      it "raises ArgumentError for an unknown status" do
        expect { described_class.new.drip_enrollments("joe@gmail.com", status: "paused") }
          .to raise_error(ArgumentError, /paused/)
      end

      # The service silently falls back to its default page size past the
      # maximum, which is worse than being told.
      it "raises ArgumentError for a page_size over the maximum" do
        expect { described_class.new.drip_enrollments("joe@gmail.com", page_size: 1_000) }
          .to raise_error(ArgumentError, /page_size/)
      end

      it "raises ArgumentError for a non-positive page_size" do
        expect { described_class.new.drip_enrollments("joe@gmail.com", page_size: 0) }
          .to raise_error(ArgumentError, /page_size/)
      end

      it "does not issue a request when an argument is invalid" do
        expect { described_class.new.drip_enrollments(nil) }.to raise_error(ArgumentError)
        expect(captured).to be_empty
      end
    end

    describe "the result" do
      subject(:result) { described_class.new.drip_enrollments("joe@gmail.com") }

      it "exposes the rows as Enrollments, newest first as the service ordered them" do
        expect(result.success?).to be(true)
        expect(result.size).to eq(2)
        expect(result.enrollments.map(&:campaign_id)).to eq(%w[trial-nurture onboarding])
      end

      it "selects the live ones" do
        expect(result.active.map(&:campaign_id)).to eq(["trial-nurture"])
        expect(result.active_campaign_names).to eq(["Trial nurture"])
      end

      # A campaign can hold more than one live run for the same recipient.
      it "deduplicates active_campaign_names" do
        rows << rows.first.merge(id: 92, correlation_key: "course:3")

        expect(result.active_campaign_names).to eq(["Trial nurture"])
      end

      it "answers active_in? by campaign id or numeric id" do
        expect(result.active_in?("trial-nurture")).to be(true)
        expect(result.active_in?(4)).to be(true)
        expect(result.active_in?("onboarding")).to be(false)
      end

      it "answers enrolled_in? for finished runs too" do
        expect(result.enrolled_in?("onboarding")).to be(true)
        expect(result.enrolled_in?(7)).to be(true)
        expect(result.enrolled_in?("never-enrolled")).to be(false)
      end

      it "reads an enrollment's fields" do
        enrollment = result.enrollments.first

        expect(enrollment.id).to eq(91)
        expect(enrollment.drip_campaign_id).to eq(4)
        expect(enrollment.topic_key).to eq("nurture")
        expect(enrollment.campaign_name).to eq("Trial nurture")
        expect(enrollment.email).to eq("joe@gmail.com")
        expect(enrollment.app_id).to eq(app_id)
        expect(enrollment.status).to eq("waiting")
        expect(enrollment.current_node_id).to eq("branch-1")
        expect(enrollment.subject_id).to eq("u_12345")
        expect(enrollment.correlation_key).to eq("course:2")
        expect(enrollment.context).to eq("course_id" => 2)
        expect(enrollment.enrolled_at).to eq(Time.utc(2026, 8, 1, 10, 0, 0))
        expect(enrollment.completed_at).to be_nil
      end

      # 'waiting' is parked on a branch condition, not finished — the whole
      # reason to read #active? instead of comparing status to "active".
      it "treats a waiting enrollment as active" do
        enrollment = result.enrollments.first

        expect(enrollment.status).to eq("waiting")
        expect(enrollment.active?).to be(true)
      end

      it "flags a stopped enrollment and its reason" do
        enrollment = result.enrollments.last

        expect(enrollment.active?).to be(false)
        expect(enrollment.stop_reason).to eq("conversion")
        expect(enrollment.stopped_at).to eq(Time.utc(2026, 7, 9, 12, 30, 0))
      end

      # Kept because the row is real history: the person genuinely was enrolled.
      it "flags an enrollment whose campaign was since deleted" do
        expect(result.enrollments.last.campaign_deleted?).to be(true)
        expect(result.enrollments.first.campaign_deleted?).to be(false)
      end

      it "reaches unmapped fields through #[] and #to_h" do
        enrollment = result.enrollments.first

        expect(enrollment[:version]).to eq(3)
        expect(enrollment.to_h).to include("version" => 3)
      end

      it "falls back to the live-status rule when the derived active flag is absent" do
        rows.first.delete(:active)

        expect(result.enrollments.first.active?).to be(true)
      end
    end

    it "returns an empty result for a recipient in nothing" do
      allow(http).to receive(:request).and_return(double("response", code: "200", body: { enrollments: [] }.to_json))

      result = described_class.new.drip_enrollments("nobody@gmail.com")

      expect(result.success?).to be(true)
      expect(result.empty?).to be(true)
      expect(result.any?).to be(false)
      expect(result.active_campaign_names).to eq([])
    end

    it "does not raise on a non-2xx, and reads as empty" do
      allow(http).to receive(:request).and_return(double("response", code: "400", body: "\"email is required\""))

      result = described_class.new.drip_enrollments("joe@gmail.com")

      expect(result.success?).to be(false)
      expect(result.status_code).to eq(400)
      expect(result.enrollments).to eq([])
    end

    it "wraps transport-level failures in Fullsend::ApiError" do
      allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)

      expect { described_class.new.drip_enrollments("joe@gmail.com") }
        .to raise_error(Fullsend::ApiError)
    end
  end

  describe "#create_unsubscribe" do
    let(:app_id) { "3163870b-4658-4d36-8a0d-e5c9d361800f" }

    let(:row) do
      {
        id: 17, email: "joe@gmail.com", app_id: app_id, campaign_id: "trial-nurture",
        scope: "campaign", reason: "manual", created_at: "2026-08-12T09:00:00Z"
      }
    end

    let(:stub_response) { double("response", code: "200", body: row.to_json) }

    before { Fullsend.configure { |c| c.fullsend_app_id = app_id } }

    def body
      JSON.parse(last_request.body)
    end

    it "POSTs the unsubscribes path" do
      described_class.new.create_unsubscribe("joe@gmail.com", scope: "campaign", campaign_id: "trial-nurture")

      expect(last_request).to be_a(Net::HTTP::Post)
      expect(last_request.path).to eq("/v1/unsubscribes")
      expect(last_request["Authorization"]).to eq("Bearer test-token")
    end

    it "sends the email, resolved app_id, scope and campaign_id" do
      described_class.new.create_unsubscribe("joe@gmail.com", scope: "campaign", campaign_id: "trial-nurture")

      expect(body).to eq(
        "email" => "joe@gmail.com", "app_id" => app_id,
        "scope" => "campaign", "campaign_id" => "trial-nurture"
      )
    end

    it "sends topic_key for a topic-scoped opt-out, lowercased" do
      described_class.new.create_unsubscribe("joe@gmail.com",
        scope: Fullsend::Client::SCOPE_TOPIC, topic_key: " Expiration_Reminders ")

      expect(body["scope"]).to eq("topic")
      expect(body["topic_key"]).to eq("expiration_reminders")
      expect(body).not_to have_key("campaign_id")
    end

    it "omits campaign_id for an app-wide opt-out" do
      described_class.new.create_unsubscribe("joe@gmail.com", scope: Fullsend::Client::SCOPE_APP)

      expect(body).not_to have_key("campaign_id")
      expect(body["scope"]).to eq("app")
    end

    # The service defaults a missing reason to "manual"; the gem does not send
    # one so that default stays in one place.
    it "omits reason unless given, and sends it when given" do
      client = described_class.new
      client.create_unsubscribe("joe@gmail.com", scope: "app")
      expect(body).not_to have_key("reason")

      client.create_unsubscribe("joe@gmail.com", scope: "app", reason: Fullsend::Client::REASON_ONE_CLICK)
      expect(body["reason"]).to eq("one_click")
    end

    it "lets an explicit app_id override the configured one" do
      described_class.new.create_unsubscribe("joe@gmail.com", scope: "app", app_id: "other-app")

      expect(body["app_id"]).to eq("other-app")
    end

    describe "argument validation" do
      it "raises ArgumentError for a blank email" do
        expect { described_class.new.create_unsubscribe("  ", scope: "app") }
          .to raise_error(ArgumentError, /email/)
      end

      # The service refuses a topic opt-out with no key; catching it here keeps
      # the failure at the call site rather than as a 400 from somewhere else.
      it "raises ArgumentError when a topic opt-out has no topic_key" do
        expect { described_class.new.create_unsubscribe("joe@gmail.com", scope: "topic") }
          .to raise_error(ArgumentError, /topic_key/)
      end

      it "requires scope to be named" do
        expect { described_class.new.create_unsubscribe("joe@gmail.com") }
          .to raise_error(ArgumentError, /scope/)
      end

      it "raises ArgumentError for an unknown scope" do
        expect { described_class.new.create_unsubscribe("joe@gmail.com", scope: "everything") }
          .to raise_error(ArgumentError, /unknown unsubscribe scope/)
      end

      # The service would default the scope to app-wide here. Opting someone out
      # of every campaign because a keyword was forgotten is the failure this
      # guard exists for.
      it "raises ArgumentError for campaign scope without a campaign_id" do
        expect { described_class.new.create_unsubscribe("joe@gmail.com", scope: "campaign") }
          .to raise_error(ArgumentError, /campaign_id is required/)
      end

      it "raises ArgumentError for an unknown reason" do
        expect { described_class.new.create_unsubscribe("joe@gmail.com", scope: "app", reason: "bored") }
          .to raise_error(ArgumentError, /unknown unsubscribe reason/)
      end

      it "raises ConfigurationError when no app_id is configured or given" do
        Fullsend.configure { |c| c.fullsend_app_id = nil }

        expect { described_class.new.create_unsubscribe("joe@gmail.com", scope: "app") }
          .to raise_error(Fullsend::ConfigurationError, /app_id/)
      end

      it "makes no request when validation fails" do
        expect { described_class.new.create_unsubscribe("joe@gmail.com", scope: "campaign") }
          .to raise_error(ArgumentError)

        expect(captured).to be_empty
      end
    end

    describe "the stored record" do
      subject(:result) do
        described_class.new.create_unsubscribe("joe@gmail.com", scope: "campaign", campaign_id: "trial-nurture")
      end

      it "reads back the row the service stored" do
        expect(result.success?).to be(true)
        expect(result.id).to eq(17)
        expect(result.email).to eq("joe@gmail.com")
        expect(result.app_id).to eq(app_id)
        expect(result.campaign_id).to eq("trial-nurture")
        expect(result.scope).to eq("campaign")
        expect(result.reason).to eq("manual")
        expect(result.created_at).to eq(Time.parse("2026-08-12T09:00:00Z"))
      end

      it "reports campaign scope as not app-wide" do
        expect(result.app_wide?).to be(false)
      end

      it "reports app scope as app-wide" do
        allow(http).to receive(:request)
          .and_return(double("response", code: "200", body: row.merge(scope: "app").to_json))

        expect(described_class.new.create_unsubscribe("joe@gmail.com", scope: "app").app_wide?).to be(true)
      end
    end

    it "does not raise on a non-2xx" do
      allow(http).to receive(:request).and_return(double("response", code: "400", body: "\"unknown app_id\""))

      result = described_class.new.create_unsubscribe("joe@gmail.com", scope: "app")

      expect(result.success?).to be(false)
      expect(result.status_code).to eq(400)
      expect(result.id).to be_nil
    end

    it "wraps transport-level failures in Fullsend::ApiError" do
      allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)

      expect { described_class.new.create_unsubscribe("joe@gmail.com", scope: "app") }
        .to raise_error(Fullsend::ApiError)
    end
  end

  describe "#unsubscribes" do
    let(:app_id) { "3163870b-4658-4d36-8a0d-e5c9d361800f" }

    let(:rows) do
      [
        {
          id: 17, email: "joe@gmail.com", app_id: app_id, campaign_id: "trial-nurture",
          scope: "campaign", reason: "manual", created_at: "2026-08-12T09:00:00Z"
        },
        {
          id: 18, email: "joe@gmail.com", app_id: app_id, campaign_id: "onboarding",
          scope: "campaign", reason: "link_click", created_at: "2026-08-11T09:00:00Z"
        }
      ]
    end

    let(:stub_response) { double("response", code: "200", body: { unsubscribes: rows }.to_json) }

    before { Fullsend.configure { |c| c.fullsend_app_id = app_id } }

    def query
      URI.decode_www_form(URI.parse(last_request.path).query.to_s).to_h
    end

    it "GETs the unsubscribes path scoped to the email and configured app" do
      described_class.new.unsubscribes("joe@gmail.com")

      expect(last_request).to be_a(Net::HTTP::Get)
      expect(URI.parse(last_request.path).path).to eq("/v1/unsubscribes")
      expect(query).to eq("email" => "joe@gmail.com", "app_id" => app_id)
    end

    it "omits app_id for ALL_APPS" do
      described_class.new.unsubscribes("joe@gmail.com", app_id: Fullsend::Client::ALL_APPS)

      expect(query).not_to have_key("app_id")
    end

    it "sends a scope filter and page_size when given" do
      described_class.new.unsubscribes("joe@gmail.com", scope: "app", page_size: 25)

      expect(query["scope"]).to eq("app")
      expect(query["page_size"]).to eq("25")
    end

    it "raises ArgumentError for an unknown scope" do
      expect { described_class.new.unsubscribes("joe@gmail.com", scope: "everything") }
        .to raise_error(ArgumentError, /unknown unsubscribe scope/)
    end

    it "raises ArgumentError for an out-of-range page_size" do
      expect { described_class.new.unsubscribes("joe@gmail.com", page_size: 0) }
        .to raise_error(ArgumentError, /page_size/)
    end

    describe "reading the rows" do
      subject(:result) { described_class.new.unsubscribes("joe@gmail.com") }

      it "maps each row" do
        expect(result.size).to eq(2)
        expect(result.unsubscribes.first.id).to eq(17)
        expect(result.unsubscribes.first.campaign_id).to eq("trial-nurture")
        expect(result.unsubscribes.first.reason).to eq("manual")
        expect(result.unsubscribes.first.created_at).to eq(Time.parse("2026-08-12T09:00:00Z"))
      end

      it "lists the campaign tags that are opted out" do
        expect(result.campaign_ids).to contain_exactly("trial-nurture", "onboarding")
      end

      it "finds a campaign's row so it can be removed by id" do
        expect(result.for_campaign("onboarding").id).to eq(18)
        expect(result.for_campaign("never-enrolled")).to be_nil
      end

      it "reports campaign-scoped suppression" do
        expect(result.suppressed?("trial-nurture")).to be(true)
        expect(result.suppressed?("weekly-tips")).to be(false)
      end

      it "is not app-wide with only campaign rows" do
        expect(result.app_wide?).to be(false)
        expect(result.app_wide).to be_nil
      end
    end

    describe "an app-wide opt-out" do
      let(:rows) do
        [{ id: 99, email: "joe@gmail.com", app_id: app_id, campaign_id: "", scope: "app", reason: "one_click" }]
      end

      subject(:result) { described_class.new.unsubscribes("joe@gmail.com") }

      it "reports app-wide and exposes the row for re-subscribing" do
        expect(result.app_wide?).to be(true)
        expect(result.app_wide.id).to eq(99)
      end

      # Matches the service's own rule: an app-scoped row suppresses every
      # campaign, whether or not a campaign row exists for it.
      it "suppresses every campaign" do
        expect(result.suppressed?("anything-at-all")).to be(true)
      end

      it "keeps app-wide rows out of campaign_ids" do
        expect(result.campaign_ids).to eq([])
      end
    end

    it "returns an empty result for an address with no opt-outs" do
      allow(http).to receive(:request).and_return(double("response", code: "200", body: { unsubscribes: [] }.to_json))

      result = described_class.new.unsubscribes("nobody@gmail.com")

      expect(result.success?).to be(true)
      expect(result.empty?).to be(true)
      expect(result.app_wide?).to be(false)
      expect(result.suppressed?("anything")).to be(false)
    end

    it "does not raise on a non-2xx, and reads as empty" do
      allow(http).to receive(:request).and_return(double("response", code: "500", body: "\"boom\""))

      result = described_class.new.unsubscribes("joe@gmail.com")

      expect(result.success?).to be(false)
      expect(result.unsubscribes).to eq([])
    end

    it "wraps transport-level failures in Fullsend::ApiError" do
      allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)

      expect { described_class.new.unsubscribes("joe@gmail.com") }
        .to raise_error(Fullsend::ApiError)
    end
  end

  describe "#delete_unsubscribe" do
    let(:stub_response) { double("response", code: "200", body: "") }

    it "DELETEs the row path" do
      described_class.new.delete_unsubscribe(17)

      expect(last_request).to be_a(Net::HTTP::Delete)
      expect(last_request.path).to eq("/v1/unsubscribes/17")
      expect(last_request["Authorization"]).to eq("Bearer test-token")
    end

    it "raises ArgumentError for a blank id" do
      expect { described_class.new.delete_unsubscribe(nil) }
        .to raise_error(ArgumentError, /id/)

      expect(captured).to be_empty
    end

    it "does not raise on a non-2xx" do
      allow(http).to receive(:request).and_return(double("response", code: "404", body: ""))

      expect(described_class.new.delete_unsubscribe(17).not_found?).to be(true)
    end
  end

  # Minting the token is the host app's job, so a callable is the supported
  # way to hand the gem a token that expires.
  describe "a callable api_token" do
    it "sends the value the callable returns" do
      Fullsend.configure { |c| c.api_token = -> { "from-callable" } }

      described_class.new.delete_ses_suppression("user@example.com")

      expect(last_request["Authorization"]).to eq("Bearer from-callable")
    end

    it "re-invokes the callable on every request so a refresh is picked up" do
      tokens = %w[first second]
      Fullsend.configure { |c| c.api_token = -> { tokens.shift } }

      client = described_class.new
      client.delete_ses_suppression("user@example.com")
      client.delete_ses_suppression("user@example.com")

      expect(captured.map { |req| req["Authorization"] })
        .to eq(["Bearer first", "Bearer second"])
    end

    it "raises ConfigurationError when the callable returns nothing" do
      Fullsend.configure { |c| c.api_token = -> {} }

      expect { described_class.new.delete_ses_suppression("user@example.com") }
        .to raise_error(Fullsend::ConfigurationError, /api_token/)
    end
  end

  describe "configuration validation" do
    it "raises ConfigurationError when api_base_url is missing" do
      Fullsend.reset_configuration!
      Fullsend.configure { |c| c.api_token = api_token }

      expect { described_class.new.delete_ses_suppression("user@example.com") }
        .to raise_error(Fullsend::ConfigurationError, /api_base_url/)
    end

    it "raises ConfigurationError when api_token is missing" do
      Fullsend.reset_configuration!
      Fullsend.configure { |c| c.api_base_url = base_url }

      expect { described_class.new.delete_ses_suppression("user@example.com") }
        .to raise_error(Fullsend::ConfigurationError, /api_token/)
    end
  end

  describe Fullsend::Client::Response do
    it "parses a JSON body via #data" do
      response = described_class.new(200, '{"removed":true}')
      expect(response.data).to eq("removed" => true)
    end

    it "returns nil from #data for an empty body" do
      expect(described_class.new(204, "").data).to be_nil
    end

    it "returns nil from #data for invalid JSON" do
      expect(described_class.new(200, "not json").data).to be_nil
    end
  end
end

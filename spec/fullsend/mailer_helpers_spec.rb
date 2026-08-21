require "spec_helper"
require "fullsend/mailer_helpers"

# Minimal test double that simulates ActionMailer's headers method
# without requiring the full ActionMailer stack (which has a Ruby 3.3
# incompatibility with ActionView 8.1.3).
class FakeMailer
  include Fullsend::MailerHelpers

  attr_reader :headers

  def initialize
    @headers = {}
  end
end

RSpec.describe Fullsend::MailerHelpers do
  let(:mailer) { FakeMailer.new }

  describe "#set_ses_headers" do
    it "sets X-SES-API header with tags and metadata" do
      mailer.set_ses_headers(
        tags: ["onboarding"],
        metadata: { user_id: "42" }
      )
      header = JSON.parse(mailer.headers["X-SES-API"])

      expect(header["tags"]).to include("onboarding")
      expect(header["metadata"]["user_id"]).to eq("42")
    end

    it "defaults campaign_id to the calling method name" do
      # Simulate what happens when a mailer action calls set_ses_headers:
      # caller_locations(1,1)[0].label returns the calling method name.
      # When called from RSpec, it will return the block label, so we
      # test the explicit campaign_id path and the caller_locations logic
      # by verifying the method doesn't return "set_ses_headers".
      mailer.set_ses_headers
      header = JSON.parse(mailer.headers["X-SES-API"])

      # The campaign_id should NOT be "set_ses_headers" (that would mean
      # the caller_locations fix is broken)
      expect(header["campaign_id"]).not_to eq("set_ses_headers")
      expect(header["campaign_id"]).to be_a(String)
      expect(header["campaign_id"].length).to be > 0
    end

    it "auto-appends campaign_id to tags" do
      mailer.set_ses_headers(campaign_id: "simple_email")
      header = JSON.parse(mailer.headers["X-SES-API"])

      expect(header["tags"]).to include("simple_email")
    end

    it "allows custom campaign_id" do
      mailer.set_ses_headers(campaign_id: "my_custom_campaign")
      header = JSON.parse(mailer.headers["X-SES-API"])

      expect(header["campaign_id"]).to eq("my_custom_campaign")
    end

    it "does not duplicate campaign_id in tags when already present" do
      mailer.set_ses_headers(
        campaign_id: "my_custom_campaign",
        tags: ["my_custom_campaign", "other"]
      )
      header = JSON.parse(mailer.headers["X-SES-API"])

      count = header["tags"].count { |t| t == "my_custom_campaign" }
      expect(count).to eq(1)
    end

    it "includes options in the header" do
      mailer.set_ses_headers(options: { open_tracking: true })
      header = JSON.parse(mailer.headers["X-SES-API"])

      expect(header["options"]["open_tracking"]).to eq(true)
    end

    it "defaults empty tags, metadata, and options" do
      mailer.set_ses_headers(campaign_id: "test")
      header = JSON.parse(mailer.headers["X-SES-API"])

      expect(header["metadata"]).to eq({})
      expect(header["options"]).to eq({})
      # tags should contain at least the campaign_id
      expect(header["tags"]).to include("test")
    end
  end

  describe "#set_template" do
    # Every destination picks up a locale (see the locale specs below), so
    # these pass an explicit one rather than depending on ambient I18n state.
    it "writes name and destinations into the X-Fullsend-Template header" do
      destinations = [
        { to: "a@example.com", data: { first_name: "Ada" } },
        { to: "b@example.com", data: { first_name: "Babbage" } }
      ]
      mailer.set_template("welcome-v1", destinations: destinations, locale: "en")
      header = JSON.parse(mailer.headers["X-Fullsend-Template"])

      expect(header["name"]).to eq("welcome-v1")
      expect(header["destinations"]).to eq([
        { "to" => "a@example.com", "data" => { "first_name" => "Ada" }, "locale" => "en" },
        { "to" => "b@example.com", "data" => { "first_name" => "Babbage" }, "locale" => "en" }
      ])
    end

    it "requires the destinations keyword argument" do
      expect { mailer.set_template("welcome-v1") }.to raise_error(ArgumentError)
    end

    it "accepts an empty destinations array" do
      mailer.set_template("welcome-v1", destinations: [])
      header = JSON.parse(mailer.headers["X-Fullsend-Template"])

      expect(header["name"]).to eq("welcome-v1")
      expect(header["destinations"]).to eq([])
    end
  end

  describe "#set_template locale" do
    def destinations_from(header_name = "X-Fullsend-Template")
      JSON.parse(mailer.headers[header_name])["destinations"]
    end

    it "keeps a per-destination locale, so one batch can mix languages" do
      mailer.set_template("welcome-v1", destinations: [
        { to: "a@example.com", data: { first_name: "Ada" }, locale: :es },
        { to: "b@example.com", data: { first_name: "Babbage" }, locale: "fr-CA" }
      ])

      expect(destinations_from.map { |d| d["locale"] }).to eq(["es", "fr-CA"])
    end

    it "normalizes a symbol locale to a string" do
      mailer.set_template("t", destinations: [{ to: "a@example.com", locale: :de }])

      expect(destinations_from.first["locale"]).to eq("de")
    end

    it "fills a missing destination locale from the batch locale" do
      mailer.set_template("t", locale: :es, destinations: [
        { to: "a@example.com", locale: :fr },
        { to: "b@example.com" }
      ])

      expect(destinations_from.map { |d| d["locale"] }).to eq(["fr", "es"])
    end

    it "treats a blank destination locale as absent" do
      mailer.set_template("t", locale: :es, destinations: [{ to: "a@example.com", locale: "" }])

      expect(destinations_from.first["locale"]).to eq("es")
    end

    it "falls back to I18n.locale when neither is given" do
      stub_const("I18n", double(locale: :"pt-BR"))
      mailer.set_template("t", destinations: [{ to: "a@example.com" }])

      expect(destinations_from.first["locale"]).to eq("pt-BR")
    end

    it "prefers an explicit locale over I18n.locale" do
      stub_const("I18n", double(locale: :en))
      mailer.set_template("t", locale: :ja, destinations: [{ to: "a@example.com" }])

      expect(destinations_from.first["locale"]).to eq("ja")
    end

    it "omits locale entirely when there is no locale to send" do
      hide_const("I18n")
      mailer.set_template("t", destinations: [{ to: "a@example.com", data: { x: 1 } }])

      expect(destinations_from.first).to eq("to" => "a@example.com", "data" => { "x" => 1 })
    end

    it "leaves other destination keys untouched" do
      mailer.set_template("t", locale: :es, destinations: [
        { to: "a@example.com", data: { first_name: "Ada" } }
      ])

      expect(destinations_from.first).to eq(
        "to" => "a@example.com",
        "data" => { "first_name" => "Ada" },
        "locale" => "es"
      )
    end

    it "handles string-keyed destinations without duplicating the locale key" do
      mailer.set_template("t", locale: :es, destinations: [
        { "to" => "a@example.com", "locale" => "fr" },
        { "to" => "b@example.com" }
      ])

      expect(destinations_from).to eq([
        { "to" => "a@example.com", "locale" => "fr" },
        { "to" => "b@example.com", "locale" => "es" }
      ])
    end

    it "does not mutate the caller's destination hashes" do
      destination = { to: "a@example.com" }
      mailer.set_template("t", locale: :es, destinations: [destination])

      expect(destination).to eq(to: "a@example.com")
    end
  end

  describe "caller_locations integration" do
    # This test verifies the critical caller_locations fix:
    # set_ses_headers resolves the caller at depth 1, which is the
    # method that called set_ses_headers (the mailer action), NOT
    # set_ses_headers itself.
    it "resolves campaign_id from the method that calls set_ses_headers" do
      # Define a method that simulates a mailer action
      def mailer.fake_action
        set_ses_headers
      end

      mailer.fake_action
      header = JSON.parse(mailer.headers["X-SES-API"])

      expect(header["campaign_id"]).to eq("fake_action")
      expect(header["tags"]).to include("fake_action")
    end
  end
end

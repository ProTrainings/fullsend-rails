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

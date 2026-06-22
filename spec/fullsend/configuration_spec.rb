require "spec_helper"
require "aws-sdk-sqs"

RSpec.describe Fullsend::Configuration do
  # All ENV vars the Configuration reads at initialize-time. Default every
  # one to nil so partial-double stubbing never raises on an unstubbed key;
  # individual examples override just the keys they care about via `env`.
  ENV_KEYS = %w[
    SQS_EMAIL_QUEUE_NAME
    AWS_S3_BUCKET_NAME
    AWS_SQS_REGION
    AWS_S3_REGION
    AWS_SES_REGION
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_REGION
    FULLSEND_API_URL
    FULLSEND_API_KEY
  ].freeze

  def stub_env(overrides = {})
    ENV_KEYS.each do |key|
      allow(ENV).to receive(:[]).with(key).and_return(overrides[key])
    end
  end

  describe "#initialize" do
    it "reads queue_name from ENV" do
      stub_env("SQS_EMAIL_QUEUE_NAME" => "MyQueue.fifo")
      expect(described_class.new.queue_name).to eq("MyQueue.fifo")
    end

    it "defaults queue_name to nil when ENV not set" do
      stub_env
      expect(described_class.new.queue_name).to be_nil
    end

    it "has nil fullsend_app_id by default" do
      expect(described_class.new.fullsend_app_id).to be_nil
    end

    it "has nil message_group_id by default" do
      expect(described_class.new.message_group_id).to be_nil
    end

    it "has an empty legacy_tag_headers by default" do
      expect(described_class.new.legacy_tag_headers).to eq([])
    end

    it "reads s3_bucket from ENV" do
      stub_env("AWS_S3_BUCKET_NAME" => "my-bucket")
      expect(described_class.new.s3_bucket).to eq("my-bucket")
    end

    it "defaults s3_bucket to nil when ENV not set" do
      stub_env
      expect(described_class.new.s3_bucket).to be_nil
    end

    it "reads sqs_region from ENV" do
      stub_env("AWS_SQS_REGION" => "us-east-1")
      expect(described_class.new.sqs_region).to eq("us-east-1")
    end

    it "defaults sqs_region to nil when ENV not set" do
      stub_env
      expect(described_class.new.sqs_region).to be_nil
    end

    it "reads s3_region from ENV" do
      stub_env("AWS_S3_REGION" => "us-west-2")
      expect(described_class.new.s3_region).to eq("us-west-2")
    end

    it "defaults s3_region to nil when ENV not set" do
      stub_env
      expect(described_class.new.s3_region).to be_nil
    end

    it "reads ses_region from ENV" do
      stub_env("AWS_SES_REGION" => "eu-west-1")
      expect(described_class.new.ses_region).to eq("eu-west-1")
    end

    it "defaults ses_region to nil when ENV not set" do
      stub_env
      expect(described_class.new.ses_region).to be_nil
    end

    it "defaults s3_key_prefix to an empty string" do
      expect(described_class.new.s3_key_prefix).to eq("")
    end
  end

  describe "#validate!" do
    it "raises ConfigurationError when fullsend_app_id is nil" do
      config = described_class.new
      config.message_group_id = "test"
      expect { config.validate! }.to raise_error(Fullsend::ConfigurationError, /fullsend_app_id/)
    end

    it "raises ConfigurationError when message_group_id is nil" do
      config = described_class.new
      config.fullsend_app_id = "test"
      expect { config.validate! }.to raise_error(Fullsend::ConfigurationError, /message_group_id/)
    end

    it "does not raise when all required fields are set" do
      config = described_class.new
      config.fullsend_app_id = "MyApp"
      config.message_group_id = "my-app"
      expect { config.validate! }.not_to raise_error
    end
  end

  describe "Fullsend API settings" do
    it "reads api_base_url and api_key from ENV" do
      stub_env(
        "FULLSEND_API_URL" => "https://api.fullsend.example",
        "FULLSEND_API_KEY" => "env-secret"
      )
      config = described_class.new
      expect(config.api_base_url).to eq("https://api.fullsend.example")
      expect(config.api_key).to eq("env-secret")
    end

    describe "#resolve_api_base_url / #resolve_api_key" do
      it "prefers explicit config over Rails credentials" do
        stub_env
        rails_app = double("Rails.application")
        credentials = double("credentials")
        allow(credentials).to receive(:fullsend).and_return({ api_base_url: "https://creds.example", api_key: "creds-key" })
        allow(rails_app).to receive(:credentials).and_return(credentials)
        stub_const("Rails", double("Rails", application: rails_app))

        config = described_class.new
        config.api_base_url = "https://explicit.example"
        config.api_key = "explicit-key"

        expect(config.resolve_api_base_url).to eq("https://explicit.example")
        expect(config.resolve_api_key).to eq("explicit-key")
      end

      it "falls back to Rails credentials under credentials.fullsend" do
        stub_env
        rails_app = double("Rails.application")
        credentials = double("credentials")
        allow(credentials).to receive(:fullsend).and_return({ api_base_url: "https://creds.example", api_key: "creds-key" })
        allow(rails_app).to receive(:credentials).and_return(credentials)
        stub_const("Rails", double("Rails", application: rails_app))

        config = described_class.new
        expect(config.resolve_api_base_url).to eq("https://creds.example")
        expect(config.resolve_api_key).to eq("creds-key")
      end

      it "accepts the legacy :url/:key credential names" do
        stub_env
        rails_app = double("Rails.application")
        credentials = double("credentials")
        allow(credentials).to receive(:fullsend).and_return({ url: "https://legacy.example", key: "legacy-key" })
        allow(rails_app).to receive(:credentials).and_return(credentials)
        stub_const("Rails", double("Rails", application: rails_app))

        config = described_class.new
        expect(config.resolve_api_base_url).to eq("https://legacy.example")
        expect(config.resolve_api_key).to eq("legacy-key")
      end
    end

    describe "#validate_api!" do
      it "raises when api_base_url is missing" do
        stub_env
        config = described_class.new
        config.api_key = "secret"
        expect { config.validate_api! }.to raise_error(Fullsend::ConfigurationError, /api_base_url/)
      end

      it "raises when api_key is missing" do
        stub_env
        config = described_class.new
        config.api_base_url = "https://api.fullsend.example"
        expect { config.validate_api! }.to raise_error(Fullsend::ConfigurationError, /api_key/)
      end

      it "does not raise when both are set" do
        stub_env
        config = described_class.new
        config.api_base_url = "https://api.fullsend.example"
        config.api_key = "secret"
        expect { config.validate_api! }.not_to raise_error
      end
    end
  end

  describe "#aws_client_options" do
    context "when ENV vars are set" do
      before do
        stub_env(
          "AWS_ACCESS_KEY_ID" => "env-key",
          "AWS_SECRET_ACCESS_KEY" => "env-secret",
          "AWS_REGION" => "us-east-1"
        )
      end

      it "returns explicit credentials and region" do
        opts = described_class.new.aws_client_options
        expect(opts[:credentials]).to be_a(Aws::Credentials)
        expect(opts[:credentials].access_key_id).to eq("env-key")
        expect(opts[:credentials].secret_access_key).to eq("env-secret")
        expect(opts[:region]).to eq("us-east-1")
      end
    end

    context "when ENV vars are not set and Rails credentials exist" do
      before do
        stub_env
        rails_app = double("Rails.application")
        credentials = double("credentials")
        allow(credentials).to receive(:aws).and_return({
          access_key_id: "cred-key",
          secret_access_key: "cred-secret",
          region: "us-west-2"
        })
        allow(rails_app).to receive(:credentials).and_return(credentials)
        stub_const("Rails", double("Rails", application: rails_app))
      end

      it "falls back to Rails credentials" do
        opts = described_class.new.aws_client_options
        expect(opts[:credentials].access_key_id).to eq("cred-key")
        expect(opts[:credentials].secret_access_key).to eq("cred-secret")
        expect(opts[:region]).to eq("us-west-2")
      end
    end

    context "when Rails credentials use access_key/secret_key keys" do
      before do
        stub_env
        rails_app = double("Rails.application")
        credentials = double("credentials")
        allow(credentials).to receive(:aws).and_return({
          access_key: "legacy-key",
          secret_key: "legacy-secret",
          region: "us-east-2"
        })
        allow(rails_app).to receive(:credentials).and_return(credentials)
        stub_const("Rails", double("Rails", application: rails_app))
      end

      it "accepts the legacy key names" do
        opts = described_class.new.aws_client_options
        expect(opts[:credentials].access_key_id).to eq("legacy-key")
        expect(opts[:credentials].secret_access_key).to eq("legacy-secret")
        expect(opts[:region]).to eq("us-east-2")
      end
    end

    context "when neither source provides credentials" do
      before { stub_env }

      it "returns empty options so the SDK uses its default credential chain" do
        hide_const("Rails")
        expect(described_class.new.aws_client_options).to eq({})
      end
    end

    context "with explicit credentials and a generic region" do
      before { stub_env }

      it "uses the configured region" do
        hide_const("Rails")
        config = described_class.new
        config.access_key_id = "explicit-key"
        config.secret_access_key = "explicit-secret"
        config.region = "us-west-1"
        opts = config.aws_client_options
        expect(opts[:credentials].access_key_id).to eq("explicit-key")
        expect(opts[:region]).to eq("us-west-1")
      end

      it "does not borrow s3_region for the generic region" do
        hide_const("Rails")
        config = described_class.new
        config.access_key_id = "explicit-key"
        config.secret_access_key = "explicit-secret"
        config.s3_region = "us-east-2"
        opts = config.aws_client_options
        expect(opts).not_to have_key(:region)
      end
    end
  end

  describe "#sqs_client_options" do
    before do
      stub_env(
        "AWS_ACCESS_KEY_ID" => "k",
        "AWS_SECRET_ACCESS_KEY" => "s",
        "AWS_REGION" => "us-east-1"
      )
    end

    it "uses the generic region when sqs_region is not set" do
      expect(described_class.new.sqs_client_options[:region]).to eq("us-east-1")
    end

    it "overrides region when sqs_region is set" do
      config = described_class.new
      config.sqs_region = "us-east-2"
      expect(config.sqs_client_options[:region]).to eq("us-east-2")
    end

    it "ignores an empty sqs_region" do
      config = described_class.new
      config.sqs_region = ""
      expect(config.sqs_client_options[:region]).to eq("us-east-1")
    end

    it "is independent of s3_region" do
      config = described_class.new
      config.sqs_region = "us-east-2"
      config.s3_region = "eu-west-1"
      expect(config.sqs_client_options[:region]).to eq("us-east-2")
    end
  end

  describe "#s3_client_options" do
    before do
      stub_env(
        "AWS_ACCESS_KEY_ID" => "k",
        "AWS_SECRET_ACCESS_KEY" => "s",
        "AWS_REGION" => "us-east-1"
      )
    end

    it "uses the generic region when s3_region is not set" do
      expect(described_class.new.s3_client_options[:region]).to eq("us-east-1")
    end

    it "overrides region when s3_region is set" do
      config = described_class.new
      config.s3_region = "us-west-2"
      expect(config.s3_client_options[:region]).to eq("us-west-2")
    end

    it "ignores an empty s3_region" do
      config = described_class.new
      config.s3_region = ""
      expect(config.s3_client_options[:region]).to eq("us-east-1")
    end

    it "is independent of sqs_region" do
      config = described_class.new
      config.s3_region = "us-west-2"
      config.sqs_region = "us-east-2"
      expect(config.s3_client_options[:region]).to eq("us-west-2")
    end

    it "preserves credentials from aws_client_options" do
      config = described_class.new
      config.s3_region = "us-west-2"
      expect(config.s3_client_options[:credentials]).to be_a(Aws::Credentials)
    end
  end
end

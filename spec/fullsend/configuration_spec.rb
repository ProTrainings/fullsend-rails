require "spec_helper"

RSpec.describe Fullsend::Configuration do
  describe "#initialize" do
    it "reads queue_name from ENV" do
      allow(ENV).to receive(:[]).with("SQS_EMAIL_QUEUE_NAME").and_return("MyQueue.fifo")
      config = described_class.new
      expect(config.queue_name).to eq("MyQueue.fifo")
    end

    it "defaults queue_name to nil when ENV not set" do
      allow(ENV).to receive(:[]).with("SQS_EMAIL_QUEUE_NAME").and_return(nil)
      config = described_class.new
      expect(config.queue_name).to be_nil
    end

    it "has nil fullsend_app_id by default" do
      config = described_class.new
      expect(config.fullsend_app_id).to be_nil
    end

    it "has nil message_group_id by default" do
      config = described_class.new
      expect(config.message_group_id).to be_nil
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

  describe "#aws_client_options" do
    context "when ENV vars are set" do
      before do
        allow(ENV).to receive(:[]).with("SQS_EMAIL_QUEUE_NAME").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_ACCESS_KEY_ID").and_return("env-key")
        allow(ENV).to receive(:[]).with("AWS_SECRET_ACCESS_KEY").and_return("env-secret")
        allow(ENV).to receive(:[]).with("AWS_REGION").and_return("us-east-1")
      end

      it "returns explicit credentials and region" do
        require "aws-sdk-sqs"
        config = described_class.new
        opts = config.aws_client_options
        expect(opts[:credentials]).to be_a(Aws::Credentials)
        expect(opts[:credentials].access_key_id).to eq("env-key")
        expect(opts[:credentials].secret_access_key).to eq("env-secret")
        expect(opts[:region]).to eq("us-east-1")
      end
    end

    context "when ENV vars are not set and Rails credentials exist" do
      before do
        allow(ENV).to receive(:[]).with("SQS_EMAIL_QUEUE_NAME").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_ACCESS_KEY_ID").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_SECRET_ACCESS_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_REGION").and_return(nil)

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
        require "aws-sdk-sqs"
        config = described_class.new
        opts = config.aws_client_options
        expect(opts[:credentials].access_key_id).to eq("cred-key")
        expect(opts[:credentials].secret_access_key).to eq("cred-secret")
        expect(opts[:region]).to eq("us-west-2")
      end
    end

    context "when Rails credentials use access_key/secret_key keys" do
      before do
        allow(ENV).to receive(:[]).with("SQS_EMAIL_QUEUE_NAME").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_ACCESS_KEY_ID").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_SECRET_ACCESS_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_REGION").and_return(nil)

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
        require "aws-sdk-sqs"
        config = described_class.new
        opts = config.aws_client_options
        expect(opts[:credentials].access_key_id).to eq("legacy-key")
        expect(opts[:credentials].secret_access_key).to eq("legacy-secret")
        expect(opts[:region]).to eq("us-east-2")
      end
    end

    context "when neither source provides credentials" do
      before do
        allow(ENV).to receive(:[]).with("SQS_EMAIL_QUEUE_NAME").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_ACCESS_KEY_ID").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_SECRET_ACCESS_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_REGION").and_return(nil)
      end

      it "returns empty options so the SDK uses its default credential chain" do
        hide_const("Rails")
        config = described_class.new
        expect(config.aws_client_options).to eq({})
      end
    end
  end
end

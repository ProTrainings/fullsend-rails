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

    it "has nil configuration_set_name by default" do
      config = described_class.new
      expect(config.configuration_set_name).to be_nil
    end

    it "has nil message_group_id by default" do
      config = described_class.new
      expect(config.message_group_id).to be_nil
    end
  end

  describe "#validate!" do
    it "raises ConfigurationError when configuration_set_name is nil" do
      config = described_class.new
      config.message_group_id = "test"
      expect { config.validate! }.to raise_error(Fullsend::ConfigurationError, /configuration_set_name/)
    end

    it "raises ConfigurationError when message_group_id is nil" do
      config = described_class.new
      config.configuration_set_name = "test"
      expect { config.validate! }.to raise_error(Fullsend::ConfigurationError, /message_group_id/)
    end

    it "does not raise when all required fields are set" do
      config = described_class.new
      config.configuration_set_name = "MyApp"
      config.message_group_id = "my-app"
      expect { config.validate! }.not_to raise_error
    end
  end

  describe "#resolve_aws_credentials" do
    context "when ENV vars are set" do
      before do
        allow(ENV).to receive(:[]).with("SQS_EMAIL_QUEUE_NAME").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_ACCESS_KEY_ID").and_return("env-key")
        allow(ENV).to receive(:[]).with("AWS_SECRET_ACCESS_KEY").and_return("env-secret")
        allow(ENV).to receive(:[]).with("AWS_REGION").and_return("us-east-1")
      end

      it "returns credentials from ENV" do
        config = described_class.new
        creds = config.resolve_aws_credentials
        expect(creds[:access_key_id]).to eq("env-key")
        expect(creds[:secret_access_key]).to eq("env-secret")
        expect(creds[:region]).to eq("us-east-1")
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
        config = described_class.new
        creds = config.resolve_aws_credentials
        expect(creds[:access_key_id]).to eq("cred-key")
        expect(creds[:secret_access_key]).to eq("cred-secret")
        expect(creds[:region]).to eq("us-west-2")
      end
    end

    context "when neither source provides credentials" do
      before do
        allow(ENV).to receive(:[]).with("SQS_EMAIL_QUEUE_NAME").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_ACCESS_KEY_ID").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_SECRET_ACCESS_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("AWS_REGION").and_return(nil)
      end

      it "raises ConfigurationError when Rails is not defined" do
        hide_const("Rails")
        config = described_class.new
        expect { config.resolve_aws_credentials }.to raise_error(Fullsend::ConfigurationError, /AWS credentials/)
      end
    end
  end
end

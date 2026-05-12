require "spec_helper"
require "mail"
require "json"

RSpec.describe Fullsend::Delivery do
  let(:sqs_client) { instance_double(Aws::SQS::Client) }
  let(:queue_url_response) { double("response", queue_url: "https://sqs.us-east-1.amazonaws.com/123456789012/test-queue.fifo") }

  around do |example|
    original_env = ENV.to_hash
    ENV["AWS_ACCESS_KEY_ID"] = "test-key"
    ENV["AWS_SECRET_ACCESS_KEY"] = "test-secret"
    ENV["AWS_REGION"] = "us-east-1"
    example.run
  ensure
    ENV.replace(original_env)
  end

  before do
    Fullsend.configure do |c|
      c.fullsend_app_id = "TestApp"
      c.message_group_id = "test-app-emailer"
    end

    allow(Aws::SQS::Client).to receive(:new).and_return(sqs_client)
    allow(sqs_client).to receive(:get_queue_url).and_return(queue_url_response)
    allow(sqs_client).to receive(:send_message)

    # Reset cached client between tests
    described_class.reset!
  end

  def template_mail(template_name: "welcome-v1", destinations: [{ to: "user@example.com", data: { first_name: "Ada" } }])
    mail = Mail.new do
      from "App <noreply@example.com>"
    end
    mail.header["X-Fullsend-Template"] = { name: template_name, destinations: destinations }.to_json
    mail
  end

  describe "#deliver!" do
    it "sends a JSON message with templateName, fromAddress, and destinations" do
      mail = template_mail(
        template_name: "welcome-v1",
        destinations: [
          { to: "a@example.com", data: { first_name: "Ada" } },
          { to: "b@example.com", data: { first_name: "Babbage" } }
        ]
      )

      delivery = described_class.new({})
      delivery.deliver!(mail)

      expect(sqs_client).to have_received(:send_message) do |args|
        body = JSON.parse(args[:message_body])
        expect(body["templateName"]).to eq("welcome-v1")
        expect(body["fromAddress"]).to eq(["App <noreply@example.com>"])
        expect(body["destinations"]).to eq([
          { "to" => "a@example.com", "data" => { "first_name" => "Ada" } },
          { "to" => "b@example.com", "data" => { "first_name" => "Babbage" } }
        ])
      end
    end

    it "omits body/toAddresses/ccAddresses/bccAddresses/subject/templateData on the templated path" do
      mail = template_mail
      mail.header["X-SES-API"] = { campaign_id: "welcome" }.to_json

      delivery = described_class.new({})
      delivery.deliver!(mail)

      expect(sqs_client).to have_received(:send_message) do |args|
        body = JSON.parse(args[:message_body])
        %w[body toAddresses ccAddresses bccAddresses subject templateData].each do |key|
          expect(body).not_to have_key(key), "expected payload not to include #{key.inspect}"
        end
      end
    end

    context "when no template header is set (non-templated email)" do
      it "sends body/toAddresses/fromAddress/subject" do
        mail = Mail.new do
          from    "App <noreply@example.com>"
          to      "user@example.com"
          subject "Welcome"
          body    "Hello there"
        end

        delivery = described_class.new({})
        delivery.deliver!(mail)

        expect(sqs_client).to have_received(:send_message) do |args|
          body = JSON.parse(args[:message_body])
          expect(body["toAddresses"]).to eq(["user@example.com"])
          expect(body["fromAddress"]).to eq(["App <noreply@example.com>"])
          expect(body["subject"]).to eq("Welcome")
          expect(body["body"]).to eq("Hello there")
        end
      end

      it "includes cc and bcc addresses" do
        mail = Mail.new do
          from    "a@b.com"
          to      "c@d.com"
          cc      "cc@d.com"
          bcc     "bcc@d.com"
          subject "Test"
          body    "body"
        end

        delivery = described_class.new({})
        delivery.deliver!(mail)

        expect(sqs_client).to have_received(:send_message) do |args|
          body = JSON.parse(args[:message_body])
          expect(body["ccAddresses"]).to eq(["cc@d.com"])
          expect(body["bccAddresses"]).to eq(["bcc@d.com"])
        end
      end

      it "does not include templateName or destinations" do
        mail = Mail.new do
          from    "a@b.com"
          to      "c@d.com"
          subject "Test"
          body    "body"
        end

        delivery = described_class.new({})
        delivery.deliver!(mail)

        expect(sqs_client).to have_received(:send_message) do |args|
          body = JSON.parse(args[:message_body])
          expect(body).not_to have_key("templateName")
          expect(body).not_to have_key("destinations")
        end
      end
    end

    it "includes fullsend_app_id as SQS message attribute" do
      delivery = described_class.new({})
      delivery.deliver!(template_mail)

      expect(sqs_client).to have_received(:send_message) do |args|
        attr = args[:message_attributes]["app_id"]
        expect(attr[:string_value]).to eq("TestApp")
        expect(attr[:data_type]).to eq("String")
      end
    end

    it "uses message_group_id from configuration" do
      delivery = described_class.new({})
      delivery.deliver!(template_mail)

      expect(sqs_client).to have_received(:send_message) do |args|
        expect(args[:message_group_id]).to eq("test-app-emailer")
      end
    end

    it "includes a unique message_deduplication_id" do
      delivery = described_class.new({})
      delivery.deliver!(template_mail)

      expect(sqs_client).to have_received(:send_message) do |args|
        expect(args[:message_deduplication_id]).to match(/\A[0-9a-f-]{36}\z/)
      end
    end

    it "extracts X-SES-API header into emailTags" do
      mail = template_mail
      mail.header["X-SES-API"] = {
        campaign_id: "welcome",
        tags: ["onboarding"],
        metadata: { user_id: "42" }
      }.to_json

      delivery = described_class.new({})
      delivery.deliver!(mail)

      expect(sqs_client).to have_received(:send_message) do |args|
        body = JSON.parse(args[:message_body])
        tags = body["emailTags"]
        expect(tags).to include({ "Name" => "campaign_id", "Value" => "welcome" })
        expect(tags).to include({ "Name" => "tag", "Value" => "onboarding" })
        expect(tags).to include({ "Name" => "user_id", "Value" => "42" })
      end
    end

    it "gracefully handles malformed X-SES-API header" do
      mail = template_mail
      mail.header["X-SES-API"] = "not-valid-json{"

      delivery = described_class.new({})
      delivery.deliver!(mail)

      expect(sqs_client).to have_received(:send_message) do |args|
        body = JSON.parse(args[:message_body])
        expect(body).not_to have_key("emailTags")
      end
    end

    it "raises MessageTooLargeError when message exceeds 256KB" do
      huge_destinations = Array.new(50) do |i|
        { to: "user#{i}@example.com", data: { blob: "x" * 6_000 } }
      end
      mail = template_mail(destinations: huge_destinations)

      delivery = described_class.new({})
      expect { delivery.deliver!(mail) }.to raise_error(Fullsend::MessageTooLargeError)
    end

    it "raises ConfigurationError when required config is missing" do
      Fullsend.reset_configuration!
      described_class.reset!

      delivery = described_class.new({})
      expect { delivery.deliver!(template_mail) }.to raise_error(Fullsend::ConfigurationError)
    end

    it "resolves queue_url once and caches it" do
      delivery1 = described_class.new({})
      delivery1.deliver!(template_mail)

      delivery2 = described_class.new({})
      delivery2.deliver!(template_mail)

      expect(sqs_client).to have_received(:get_queue_url).once
    end

    it "gracefully handles malformed X-Fullsend-Template header" do
      mail = Mail.new do
        from "a@b.com"
      end
      mail.header["X-Fullsend-Template"] = "not-valid-json{"

      delivery = described_class.new({})
      delivery.deliver!(mail)

      expect(sqs_client).to have_received(:send_message) do |args|
        body = JSON.parse(args[:message_body])
        expect(body).not_to have_key("templateName")
        expect(body).not_to have_key("destinations")
      end
    end
  end
end

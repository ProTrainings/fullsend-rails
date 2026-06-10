require "spec_helper"
require "mail"
require "json"

RSpec.describe Fullsend::Delivery do
  let(:sqs_client) { instance_double(Aws::SQS::Client) }
  let(:s3_client) { instance_double(Aws::S3::Client) }
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

    allow(Aws::S3::Client).to receive(:new).and_return(s3_client)
    allow(s3_client).to receive(:put_object)

    # Reset cached client between tests
    described_class.reset!
  end

  def template_mail(template_name: "welcome-v1", destinations: [{ to: "user@example.com", data: { first_name: "Ada" } }], subject: "Welcome")
    mail = Mail.new do
      from "App <noreply@example.com>"
    end
    mail.subject = subject if subject
    mail.header["X-Fullsend-Template"] = { name: template_name, destinations: destinations }.to_json
    mail
  end

  describe "#deliver!" do
    it "sends a JSON message with templateName, fromAddress, subject, and destinations" do
      mail = template_mail(
        template_name: "welcome-v1",
        subject: "Welcome!",
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
        expect(body["subject"]).to eq("Welcome!")
        expect(body["destinations"]).to eq([
          { "to" => "a@example.com", "data" => { "first_name" => "Ada" } },
          { "to" => "b@example.com", "data" => { "first_name" => "Babbage" } }
        ])
      end
    end

    it "omits body/toAddresses/ccAddresses/bccAddresses/templateData on the templated path" do
      mail = template_mail
      mail.header["X-SES-API"] = { campaign_id: "welcome" }.to_json

      delivery = described_class.new({})
      delivery.deliver!(mail)

      expect(sqs_client).to have_received(:send_message) do |args|
        body = JSON.parse(args[:message_body])
        %w[body toAddresses ccAddresses bccAddresses templateData].each do |key|
          expect(body).not_to have_key(key), "expected payload not to include #{key.inspect}"
        end
      end
    end

    context "with ses_region configured" do
      it "includes sesRegion in the payload" do
        Fullsend.configuration.ses_region = "eu-west-1"
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
          expect(body["sesRegion"]).to eq("eu-west-1")
        end
      ensure
        Fullsend.configuration.ses_region = nil
      end
    end

    it "omits sesRegion when ses_region is not configured" do
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
        expect(body).not_to have_key("sesRegion")
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

    context "with legacy_tag_headers configured" do
      before do
        Fullsend.configuration.legacy_tag_headers = ["X-MSYS-API"]
      end

      it "extracts a legacy header into emailTags when X-SES-API is absent" do
        mail = template_mail
        mail.header["X-MSYS-API"] = {
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

      it "prefers X-SES-API over the legacy header when both are present" do
        mail = template_mail
        mail.header["X-SES-API"] = { campaign_id: "ses-wins" }.to_json
        mail.header["X-MSYS-API"] = { campaign_id: "msys-loses" }.to_json

        delivery = described_class.new({})
        delivery.deliver!(mail)

        expect(sqs_client).to have_received(:send_message) do |args|
          body = JSON.parse(args[:message_body])
          expect(body["emailTags"]).to include({ "Name" => "campaign_id", "Value" => "ses-wins" })
          expect(body["emailTags"]).not_to include({ "Name" => "campaign_id", "Value" => "msys-loses" })
        end
      end

      it "ignores legacy headers that are not configured" do
        mail = template_mail
        mail.header["X-OTHER-API"] = { campaign_id: "ignored" }.to_json

        delivery = described_class.new({})
        delivery.deliver!(mail)

        expect(sqs_client).to have_received(:send_message) do |args|
          body = JSON.parse(args[:message_body])
          expect(body).not_to have_key("emailTags")
        end
      end
    end

    it "ignores a legacy header when legacy_tag_headers is unset (default)" do
      mail = template_mail
      mail.header["X-MSYS-API"] = { campaign_id: "welcome" }.to_json

      delivery = described_class.new({})
      delivery.deliver!(mail)

      expect(sqs_client).to have_received(:send_message) do |args|
        body = JSON.parse(args[:message_body])
        expect(body).not_to have_key("emailTags")
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

    context "with attachments" do
      before do
        Fullsend.configure do |c|
          c.s3_bucket = "fullsend-attachments"
          c.s3_key_prefix = "outgoing/"
        end
      end

      def mail_with_attachment(filename: "receipt.pdf", content: "%PDF-1.4 binary bytes", template: false)
        mail = Mail.new do
          from "App <noreply@example.com>"
          to   "user@example.com"
        end
        mail.subject = "Your receipt"
        mail.body = "Thanks!" unless template
        mail.attachments[filename] = content
        if template
          mail.header["X-Fullsend-Template"] = { name: "receipt-v1", destinations: [{ to: "user@example.com" }] }.to_json
        end
        mail
      end

      it "uploads each attachment to S3 with prefix/<uuid>-<filename> key" do
        mail = mail_with_attachment

        delivery = described_class.new({})
        delivery.deliver!(mail)

        expect(s3_client).to have_received(:put_object).once do |args|
          expect(args[:bucket]).to eq("fullsend-attachments")
          expect(args[:key]).to match(%r{\Aoutgoing/[0-9a-f-]{36}-receipt\.pdf\z})
          expect(args[:body]).to include("%PDF-1.4")
          expect(args[:content_type]).to eq("application/pdf")
        end
      end

      it "includes the S3 keys in the SQS message's attachments array" do
        mail = Mail.new do
          from "a@b.com"
          to   "c@d.com"
          subject "Test"
          body "body"
        end
        mail.attachments["a.pdf"] = "PDF A"
        mail.attachments["b.csv"] = "col1,col2\n1,2"

        delivery = described_class.new({})
        delivery.deliver!(mail)

        expect(sqs_client).to have_received(:send_message) do |args|
          body = JSON.parse(args[:message_body])
          expect(body["attachments"].length).to eq(2)
          expect(body["attachments"][0]).to match(%r{\Aoutgoing/[0-9a-f-]{36}-a\.pdf\z})
          expect(body["attachments"][1]).to match(%r{\Aoutgoing/[0-9a-f-]{36}-b\.csv\z})
        end
      end

      it "omits attachments key from the SQS message when there are none" do
        mail = Mail.new do
          from "a@b.com"
          to   "c@d.com"
          subject "Test"
          body "body"
        end

        delivery = described_class.new({})
        delivery.deliver!(mail)

        expect(s3_client).not_to have_received(:put_object)
        expect(sqs_client).to have_received(:send_message) do |args|
          body = JSON.parse(args[:message_body])
          expect(body).not_to have_key("attachments")
        end
      end

      it "includes attachments on the templated path too" do
        mail = mail_with_attachment(template: true)

        delivery = described_class.new({})
        delivery.deliver!(mail)

        expect(s3_client).to have_received(:put_object).once
        expect(sqs_client).to have_received(:send_message) do |args|
          body = JSON.parse(args[:message_body])
          expect(body["templateName"]).to eq("receipt-v1")
          expect(body["attachments"].length).to eq(1)
          expect(body["attachments"][0]).to match(/receipt\.pdf\z/)
        end
      end

      it "raises ConfigurationError when attachments are present but bucket is not configured" do
        Fullsend.configuration.s3_bucket = nil
        described_class.reset!

        mail = mail_with_attachment

        delivery = described_class.new({})
        expect { delivery.deliver!(mail) }.to raise_error(Fullsend::ConfigurationError, /s3_bucket/)
        expect(sqs_client).not_to have_received(:send_message)
      end

      it "does not enqueue an SQS message when an S3 PUT fails" do
        allow(s3_client).to receive(:put_object).and_raise(Aws::S3::Errors::ServiceError.new(nil, "boom"))

        mail = mail_with_attachment

        delivery = described_class.new({})
        expect { delivery.deliver!(mail) }.to raise_error(Aws::S3::Errors::ServiceError)
        expect(sqs_client).not_to have_received(:send_message)
      end

      it "strips any path components from the attachment filename" do
        mail = Mail.new do
          from "a@b.com"
          to   "c@d.com"
          subject "Test"
          body "body"
        end
        mail.attachments["../../etc/passwd.txt"] = "secret"

        delivery = described_class.new({})
        delivery.deliver!(mail)

        expect(s3_client).to have_received(:put_object) do |args|
          expect(args[:key]).to match(%r{\Aoutgoing/[0-9a-f-]{36}-passwd\.txt\z})
        end
      end

      it "works without a configured prefix" do
        Fullsend.configuration.s3_key_prefix = ""
        described_class.reset!

        mail = mail_with_attachment(filename: "doc.pdf")

        delivery = described_class.new({})
        delivery.deliver!(mail)

        expect(s3_client).to have_received(:put_object) do |args|
          expect(args[:key]).to match(/\A[0-9a-f-]{36}-doc\.pdf\z/)
        end
      end

      it "builds the S3 client with s3_region when set, overriding the SQS region" do
        Fullsend.configuration.s3_region = "us-west-2"
        described_class.reset!

        mail = mail_with_attachment

        delivery = described_class.new({})
        delivery.deliver!(mail)

        expect(Aws::S3::Client).to have_received(:new).with(hash_including(region: "us-west-2"))
        expect(Aws::SQS::Client).to have_received(:new).with(hash_including(region: "us-east-1"))
      end
    end
  end
end

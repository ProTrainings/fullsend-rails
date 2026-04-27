require "aws-sdk-sqs"
require "json"
require "securerandom"
require "active_support/core_ext/object/blank"

module Fullsend
  class Delivery
    MAX_SQS_MESSAGE_SIZE = 262_144

    @mutex = Mutex.new
    @sqs_client = nil
    @queue_url = nil

    class << self
      def reset!
        @mutex.synchronize do
          @sqs_client = nil
          @queue_url = nil
        end
      end

      def sqs_client
        @mutex.synchronize do
          @sqs_client ||= Aws::SQS::Client.new(Fullsend.configuration.aws_client_options)
        end
      end

      def queue_url
        # Resolve client outside our mutex to avoid deadlock —
        # sqs_client has its own mutex acquisition.
        client = sqs_client
        @mutex.synchronize do
          @queue_url ||= begin
            queue_name = Fullsend.configuration.queue_name
            client.get_queue_url(queue_name: queue_name).queue_url
          end
        end
      end
    end

    def initialize(_options)
      # Options accepted by ActionMailer but not needed here
    end

    def deliver!(mail)
      config = Fullsend.configuration
      config.validate!

      message = build_message(mail)
      message_json = message.to_json
      message_size = message_json.bytesize

      if message_size > MAX_SQS_MESSAGE_SIZE
        raise MessageTooLargeError,
          "Email message too large for SQS delivery: #{message_size} bytes (limit: #{MAX_SQS_MESSAGE_SIZE})"
      end

      self.class.sqs_client.send_message(
        queue_url: self.class.queue_url,
        message_group_id: config.message_group_id,
        message_body: message_json,
        message_deduplication_id: SecureRandom.uuid,
        message_attributes: {
          "app_id" => {
            string_value: config.fullsend_app_id,
            data_type: "String"
          }
        }
      )
    end

    private

    def build_message(mail)
      message = {
        body: mail.body.raw_source,
        toAddresses: mail["to"]&.formatted,
        ccAddresses: mail["cc"]&.formatted,
        bccAddresses: mail["bcc"]&.formatted,
        fromAddress: mail["from"]&.formatted,
        subject: mail.subject
      }

      extract_template(mail, message)
      extract_ses_tags(mail, message)
      message
    end

    def extract_template(mail, message)
      return unless mail.header["X-Fullsend-Template"].present?

      template = JSON.parse(mail.header["X-Fullsend-Template"].value)
      message[:templateName] = template["name"] if template["name"]
      message[:templateData] = template["data"] if template.key?("data")
    rescue JSON::ParserError
      warn "[Fullsend] Failed to parse X-Fullsend-Template header: #{mail.header["X-Fullsend-Template"].value}"
    end

    def extract_ses_tags(mail, message)
      return unless mail.header["X-SES-API"].present?

      ses_data = JSON.parse(mail.header["X-SES-API"].value)
      email_tags = []

      if ses_data["campaign_id"]
        email_tags << { Name: "campaign_id", Value: ses_data["campaign_id"] }
      end

      if ses_data["tags"].is_a?(Array)
        ses_data["tags"].each do |tag|
          email_tags << { Name: "tag", Value: tag }
        end
      end

      if ses_data["metadata"].is_a?(Hash)
        ses_data["metadata"].each do |key, value|
          email_tags << { Name: key, Value: value.to_s }
        end
      end

      message[:emailTags] = email_tags unless email_tags.empty?
    rescue JSON::ParserError
      warn "[Fullsend] Failed to parse X-SES-API header: #{mail.header["X-SES-API"].value}"
    end
  end
end

module Fullsend
  class Configuration
    attr_accessor :queue_name, :fullsend_app_id, :message_group_id

    def initialize
      @queue_name        = ENV["SQS_EMAIL_QUEUE_NAME"]
      @fullsend_app_id   = nil
      @message_group_id  = nil
    end

    def validate!
      if fullsend_app_id.nil? || fullsend_app_id.empty?
        raise ConfigurationError, "fullsend_app_id is required. Set it via Fullsend.configure."
      end

      if message_group_id.nil? || message_group_id.empty?
        raise ConfigurationError, "message_group_id is required. Set it via Fullsend.configure."
      end
    end

    def resolve_aws_credentials
      access_key_id     = ENV["AWS_ACCESS_KEY_ID"]
      secret_access_key = ENV["AWS_SECRET_ACCESS_KEY"]
      region            = ENV["AWS_REGION"]

      if access_key_id && secret_access_key && region
        return { access_key_id: access_key_id, secret_access_key: secret_access_key, region: region }
      end

      if defined?(Rails) && Rails.application.respond_to?(:credentials)
        aws = Rails.application.credentials.aws
        if aws
          return {
            access_key_id: aws[:access_key_id],
            secret_access_key: aws[:secret_access_key],
            region: aws[:region]
          }
        end
      end

      raise ConfigurationError,
        "AWS credentials not found. Set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_REGION " \
        "environment variables, or configure Rails encrypted credentials under credentials.aws."
    end
  end
end

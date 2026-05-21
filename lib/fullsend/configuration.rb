module Fullsend
  class Configuration
    attr_accessor :queue_name, :fullsend_app_id, :message_group_id,
                  :s3_bucket, :s3_key_prefix,
                  :s3_region,
                  :access_key_id, :secret_access_key, :region

    def initialize
      @queue_name              = ENV["SQS_EMAIL_QUEUE_NAME"]
      @fullsend_app_id         = nil
      @message_group_id        = nil
      @s3_bucket      = ENV["AWS_S3_BUCKET_NAME"]
      @s3_key_prefix  = ""
      @s3_region      = ENV["AWS_S3_REGION"]
      @access_key_id           = nil
      @secret_access_key       = nil
      @region                  = nil
    end

    def validate!
      if fullsend_app_id.nil? || fullsend_app_id.empty?
        raise ConfigurationError, "fullsend_app_id is required. Set it via Fullsend.configure."
      end

      if message_group_id.nil? || message_group_id.empty?
        raise ConfigurationError, "message_group_id is required. Set it via Fullsend.configure."
      end
    end

    # Returns options to pass to Aws::SQS::Client.new. Resolution order:
    # 1. Explicit values set on Fullsend.configure (access_key_id, secret_access_key, region)
    # 2. AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION env vars
    # 3. Rails encrypted credentials (Rails.application.credentials.aws)
    # 4. SDK default credential chain (Aws.config, instance profile, shared config, etc.)
    def aws_client_options
      options = {}

      if access_key_id && secret_access_key
        options[:credentials] = Aws::Credentials.new(access_key_id, secret_access_key)
        options[:region] = region if region
        return options
      end

      env_creds = aws_env_credentials
      rails_creds = aws_rails_credentials

      if env_creds
        options[:credentials] = Aws::Credentials.new(env_creds[:access_key_id], env_creds[:secret_access_key])
        options[:region] = env_creds[:region] if env_creds[:region]
      elsif rails_creds && rails_creds[:access_key_id] && rails_creds[:secret_access_key]
        options[:credentials] = Aws::Credentials.new(rails_creds[:access_key_id], rails_creds[:secret_access_key])
        options[:region] = rails_creds[:region] if rails_creds[:region]
      elsif rails_creds && rails_creds[:region]
        options[:region] = rails_creds[:region]
      end

      options[:region] ||= region if region
      options
    end

    # Returns options to pass to Aws::S3::Client.new. Identical to
    # aws_client_options except that :region is overridden by
    # s3_region when set — useful when the S3 attachments bucket
    # lives in a different region than the SQS queue.
    def s3_client_options
      options = aws_client_options
      options = options.merge(region: s3_region) if s3_region && !s3_region.empty?
      options
    end

    private

    def aws_env_credentials
      access_key_id     = ENV["AWS_ACCESS_KEY_ID"]
      secret_access_key = ENV["AWS_SECRET_ACCESS_KEY"]
      return nil unless access_key_id && secret_access_key

      { access_key_id: access_key_id, secret_access_key: secret_access_key, region: ENV["AWS_REGION"] }
    end

    def aws_rails_credentials
      return nil unless defined?(Rails) && Rails.application.respond_to?(:credentials)

      aws = Rails.application.credentials.aws
      return nil unless aws

      {
        access_key_id: aws[:access_key_id] || aws[:access_key],
        secret_access_key: aws[:secret_access_key] || aws[:secret_key],
        region: aws[:region]
      }
    end
  end
end

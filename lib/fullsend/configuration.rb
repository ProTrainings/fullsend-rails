module Fullsend
  class Configuration
    attr_accessor :queue_name, :fullsend_app_id, :message_group_id,
                  :s3_bucket, :s3_key_prefix,
                  :sqs_region, :s3_region, :ses_region,
                  :access_key_id, :secret_access_key, :region,
                  :legacy_tag_headers

    def initialize
      @queue_name              = ENV["SQS_EMAIL_QUEUE_NAME"]
      @fullsend_app_id         = nil
      @message_group_id        = nil
      @s3_bucket      = ENV["AWS_S3_BUCKET_NAME"]
      @s3_key_prefix  = ""
      # Per-service regions. Each AWS service can live in its own region;
      # when a service's region is unset it falls back to the generic
      # `region` (AWS_REGION) below.
      #   sqs_region (AWS_SQS_REGION) -> the SQS client
      #   s3_region  (AWS_S3_REGION)  -> the S3 attachments client
      #   ses_region (AWS_SES_REGION) -> carried in the SQS payload as
      #     "sesRegion" for the downstream SES sender. This gem makes no
      #     SES calls itself; it only enqueues to SQS.
      @sqs_region     = ENV["AWS_SQS_REGION"]
      @s3_region      = ENV["AWS_S3_REGION"]
      @ses_region     = ENV["AWS_SES_REGION"]
      @access_key_id           = nil
      @secret_access_key       = nil
      # Generic default region (AWS_REGION). Used for credential resolution
      # and as the fallback for any service whose *_region is unset.
      @region                  = nil
      # Extra header names whose value carries SES-tag-shaped JSON
      # (tags/campaign_id/metadata), read as a fallback when X-SES-API
      # is absent. Lets an app migrating off another provider keep
      # emitting its legacy header (e.g. "X-MSYS-API") without rewriting
      # every mailer. Empty by default — the gem stays provider-agnostic.
      @legacy_tag_headers      = []
    end

    def validate!
      if fullsend_app_id.nil? || fullsend_app_id.empty?
        raise ConfigurationError, "fullsend_app_id is required. Set it via Fullsend.configure."
      end

      if message_group_id.nil? || message_group_id.empty?
        raise ConfigurationError, "message_group_id is required. Set it via Fullsend.configure."
      end
    end

    # Resolves AWS credentials and the generic default region, shared by
    # every client. Resolution order:
    # 1. Explicit values set on Fullsend.configure (access_key_id, secret_access_key, region)
    # 2. AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION env vars
    # 3. Rails encrypted credentials (Rails.application.credentials.aws)
    # 4. SDK default credential chain (Aws.config, instance profile, shared config, etc.)
    #
    # The :region here is the *generic* fallback; per-service callers
    # (sqs_client_options / s3_client_options) override it with their own
    # region when one is configured.
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

    # Options for Aws::SQS::Client.new — base credentials with the region
    # overridden by sqs_region when set.
    def sqs_client_options
      apply_region(aws_client_options, sqs_region)
    end

    # Options for Aws::S3::Client.new — base credentials with the region
    # overridden by s3_region when set. Useful when the attachments bucket
    # lives in a different region than the SQS queue.
    def s3_client_options
      apply_region(aws_client_options, s3_region)
    end

    private

    def apply_region(options, override)
      return options if override.nil? || override.to_s.empty?

      options.merge(region: override)
    end

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

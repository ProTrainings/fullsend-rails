require "active_support/concern"
require "active_support/core_ext/hash/reverse_merge"
require "json"

module Fullsend
  module MailerHelpers
    extend ActiveSupport::Concern

    def set_ses_headers(**args)
      # Resolve caller at this frame — the mailer action (e.g. "welcome")
      # is one frame up from here. We pass it explicitly so
      # apply_provider_headers doesn't get "set_ses_headers" as the caller.
      unless args.key?(:campaign_id)
        args[:campaign_id] = caller_locations(1, 1)[0].label
      end
      apply_provider_headers("X-SES-API", **args)
    end

    def set_template(name, data: nil)
      payload = { name: name }
      payload[:data] = data unless data.nil?
      headers["X-Fullsend-Template"] = payload.to_json
    end

    def apply_provider_headers(header_key, **args)
      calling_method = args[:campaign_id] || caller_locations(1, 1)[0].label
      calling_method = "" if calling_method == "irb_binding"

      args.reverse_merge!(tags: [], campaign_id: calling_method, metadata: {}, options: {})
      args[:tags] << args[:campaign_id] unless args[:tags].include?(args[:campaign_id])

      header_hash = {
        tags: args[:tags],
        campaign_id: args[:campaign_id],
        metadata: args[:metadata],
        options: args[:options]
      }
      headers[header_key] = header_hash.to_json
    end
  end
end

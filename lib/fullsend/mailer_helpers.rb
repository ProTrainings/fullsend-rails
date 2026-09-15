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

    # Names the template a message is rendered from. Two shapes:
    #
    # Batch — `destinations:`. Recipients in one batch can speak different
    # languages, so the locale rides on each destination rather than on the
    # message. Pass it per entry; `locale:` here is the batch fallback for
    # entries that omit one, and defaults to I18n.locale.
    #
    #   set_template("welcome-v1", destinations: [
    #     { to: "ada@example.com", data: { first_name: "Ada" }, locale: :es },
    #     { to: "bob@example.com", data: { first_name: "Bob" } } # => I18n.locale
    #   ])
    #
    # Single recipient — `data:`. Addresses stay on the Mail object, so this is
    # the shape to use when a templated message has to carry a Cc or Bcc:
    # destinations[] cannot, because the fan-out that splits a batch into one
    # message per recipient drops them. It also keeps the message on the
    # transactional lane, which rejects anything carrying destinations[].
    #
    #   mail(to: user.email, cc: manager.email, subject: "...")
    #   set_template("receipt-v1", data: { first_name: "Ada" })
    def set_template(name, destinations: nil, data: nil, locale: nil)
      if destinations.nil? && data.nil?
        raise ArgumentError, "set_template needs destinations: (a batch) or data: (one recipient)"
      end

      fallback = fullsend_normalize_locale(locale) || fullsend_current_locale

      headers["X-Fullsend-Template"] =
        if destinations.nil?
          payload = { name: name, data: data }
          payload[:locale] = fallback if fallback
          payload.to_json
        else
          resolved = Array(destinations).map do |destination|
            fullsend_apply_destination_locale(destination, fallback)
          end
          { name: name, destinations: resolved }.to_json
        end
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

    private

    # Preserves the caller's key style — a string-keyed destination stays
    # string-keyed — so the hash round-trips to the same JSON either way.
    def fullsend_apply_destination_locale(destination, fallback)
      destination = destination.to_h
      key = destination.key?("locale") ? "locale" : :locale
      locale = fullsend_normalize_locale(destination[key]) || fallback
      return destination if locale.nil?

      destination.merge(key => locale)
    end

    def fullsend_normalize_locale(value)
      value = value.to_s
      value.empty? ? nil : value
    end

    # nil rather than a guess when I18n is absent: better to send no locale
    # than a wrong one the downstream service would render against.
    def fullsend_current_locale
      return nil unless defined?(I18n) && I18n.respond_to?(:locale)

      fullsend_normalize_locale(I18n.locale)
    end
  end
end

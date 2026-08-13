require "fullsend/version"
require "fullsend/errors"
require "fullsend/configuration"
require "fullsend/delivery"
require "fullsend/client"
require "fullsend/mailer_helpers"
require "fullsend/railtie" if defined?(Rails::Railtie)

module Fullsend
  # Lazy so an app that never tracks events never loads ActiveJob.
  autoload :EventJob, "fullsend/event_job"

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    # Report a domain event to the automation intake, synchronously.
    #
    #   Fullsend.track_event("course.started",
    #     email: user.email,
    #     subject_id: "u_#{user.id}",
    #     properties: { course_id: course.id, course_name: course.name })
    #
    # Returns a Fullsend::Client::EventResult. See Client#track_event.
    def track_event(event_key, **options)
      Client.new.track_event(event_key, **options)
    end

    # The same, enqueued via ActiveJob — the right default from a request or
    # a model callback, where an HTTP round-trip does not belong. Arguments
    # must be JSON-serializable; see Fullsend::EventJob.
    def track_event_later(event_key, **options)
      EventJob.perform_later(event_key, **options)
    end

    # Which automations is this address enrolled in?
    #
    #   Fullsend.drip_enrollments(user.email).active_campaign_names
    #
    # Scoped to the configured fullsend_app_id by default. Returns a
    # Fullsend::Client::DripEnrollmentsResult. See Client#drip_enrollments.
    def drip_enrollments(email, **options)
      Client.new.drip_enrollments(email, **options)
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end

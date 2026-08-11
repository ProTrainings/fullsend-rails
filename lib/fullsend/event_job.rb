require "active_job"

module Fullsend
  # Reports an event to the Fullsend intake off the request path.
  #
  # Event triggers fire from ordinary app code — a user starts a course, an
  # order ships — where a synchronous HTTP round-trip would put an external
  # service in the critical path of a user action. Enqueue instead:
  #
  #   Fullsend.track_event_later("course.started", email: user.email, ...)
  #
  # Loaded lazily (see the autoload in fullsend.rb) so an app that never
  # enqueues events never pulls in ActiveJob.
  #
  # Arguments must survive ActiveJob serialization — keep `properties` to
  # strings, numbers, booleans, arrays, and hashes of the same. Passing a
  # record raises at enqueue time; pass its attributes instead.
  class EventJob < ActiveJob::Base
    queue_as { Fullsend.configuration.event_queue_name || :default }

    # A failed intake call is worth retrying: the event is a fact that already
    # happened, and losing it silently un-arms whatever automation listens for
    # it. Backoff is spelled out rather than using :polynomially_longer /
    # :exponentially_longer, whose names differ across the Rails versions this
    # gem supports.
    retry_on Fullsend::ApiError, wait: ->(executions) { (executions**4) + 2 }, attempts: 5

    # A misconfigured app_id or a missing event_key/email will fail the same
    # way on every attempt, so surface it immediately instead of burning
    # retries on it.
    discard_on Fullsend::ConfigurationError, ArgumentError

    def perform(event_key, email:, subject_id: nil, properties: nil, app_id: nil)
      response = Client.new.track_event(
        event_key,
        email: email,
        subject_id: subject_id,
        properties: properties,
        app_id: app_id
      )

      # track_event returns non-2xx as a Response rather than raising, which is
      # right for a caller that wants to branch on the status. In a job there is
      # no such caller, and a 5xx should come back around — so raise.
      unless response.success?
        raise ApiError.new(
          "Fullsend event #{event_key} rejected with HTTP #{response.status_code}",
          status_code: response.status_code,
          body: response.body
        )
      end

      response
    end
  end
end

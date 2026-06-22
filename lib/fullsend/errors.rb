module Fullsend
  class ConfigurationError < StandardError; end
  class MessageTooLargeError < StandardError; end

  # Raised when a request to the Fullsend HTTP API fails — either a
  # transport-level error (connection refused, timeout, DNS) or, if you
  # opt into +raise_on_error+, a non-2xx response. Carries the HTTP
  # status code when one is available (nil for transport errors).
  class ApiError < StandardError
    attr_reader :status_code, :body

    def initialize(message, status_code: nil, body: nil)
      super(message)
      @status_code = status_code
      @body = body
    end
  end
end

require "fullsend/version"
require "fullsend/errors"
require "fullsend/configuration"
require "fullsend/delivery"
require "fullsend/mailer_helpers"
require "fullsend/railtie" if defined?(Rails::Railtie)

module Fullsend
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end

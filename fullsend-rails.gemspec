lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "fullsend/version"

Gem::Specification.new do |spec|
  spec.name          = "fullsend-rails"
  spec.version       = Fullsend::VERSION
  spec.authors       = ["ProTrainings"]
  spec.email         = ["dev@protrainings.com"]
  spec.summary       = "SQS-based ActionMailer delivery for the Fullsend email service"
  spec.description   = "Rails gem providing an ActionMailer delivery method that sends emails as JSON to an SQS FIFO queue, plus campaign tracking header helpers."
  spec.homepage      = "https://github.com/protrainings/fullsend-rails"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files         = Dir["lib/**/*", "LICENSE.txt", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "aws-sdk-sqs", "~> 1.0"
  spec.add_dependency "rails", ">= 6.0"

  spec.add_development_dependency "rspec", "~> 3.0"
end

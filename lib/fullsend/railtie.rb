module Fullsend
  class Railtie < Rails::Railtie
    initializer "fullsend.add_delivery_method" do
      ActiveSupport.on_load(:action_mailer) do
        ActionMailer::Base.add_delivery_method :fullsend, Fullsend::Delivery
      end
    end
  end
end

require "spec_helper"
require "active_job"

RSpec.describe Fullsend::EventJob do
  let(:client) { instance_double(Fullsend::Client) }
  let(:response) { Fullsend::Client::EventResult.new(200, { registered: true }.to_json) }

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    described_class.queue_adapter.enqueued_jobs.clear if described_class.queue_adapter.respond_to?(:enqueued_jobs)
  end

  before do
    allow(Fullsend::Client).to receive(:new).and_return(client)
    allow(client).to receive(:track_event).and_return(response)
  end

  it "forwards every field to the client" do
    described_class.perform_now(
      "course.started",
      email: "joe@gmail.com",
      subject_id: "u_12345",
      properties: { "course_id" => 2 },
      app_id: "app-1"
    )

    expect(client).to have_received(:track_event).with(
      "course.started",
      email: "joe@gmail.com",
      subject_id: "u_12345",
      properties: { "course_id" => 2 },
      app_id: "app-1"
    )
  end

  # The client returns a non-2xx rather than raising, which suits a caller that
  # wants to branch. A job has no such caller, so it has to raise to retry.
  context "on a non-2xx" do
    before do
      allow(client).to receive(:track_event).and_return(Fullsend::Client::EventResult.new(500, "boom"))
    end

    it "raises ApiError carrying the status" do
      expect { described_class.new.perform("course.started", email: "joe@gmail.com") }
        .to raise_error(Fullsend::ApiError) { |e| expect(e.status_code).to eq(500) }
    end

    # retry_on catches that ApiError and re-enqueues rather than letting it
    # escape — the event is a fact that already happened, so losing it would
    # silently un-arm whatever automation listens for the key.
    it "re-enqueues instead of dropping the event" do
      expect { described_class.perform_now("course.started", email: "joe@gmail.com") }
        .to change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }.by(1)
    end
  end

  it "does not raise for an accepted-but-unregistered key" do
    allow(client).to receive(:track_event)
      .and_return(Fullsend::Client::EventResult.new(200, { registered: false }.to_json))

    expect { described_class.perform_now("nope", email: "joe@gmail.com") }.not_to raise_error
  end

  it "uses the configured event queue" do
    Fullsend.configure { |c| c.event_queue_name = "fullsend_events" }

    expect(described_class.new("course.started", email: "joe@gmail.com").queue_name).to eq("fullsend_events")
  end

  it "falls back to the default queue" do
    Fullsend.configure { |c| c.event_queue_name = nil }

    expect(described_class.new("course.started", email: "joe@gmail.com").queue_name).to eq("default")
  end

  describe "Fullsend.track_event_later" do
    it "enqueues the job with the event arguments" do
      Fullsend.track_event_later("course.started", email: "joe@gmail.com", properties: { "course_id" => 2 })

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job["job_class"] || job[:job]).to satisfy { |k| k.to_s.include?("Fullsend::EventJob") }
      expect(client).not_to have_received(:track_event)
    end
  end

  describe "Fullsend.track_event" do
    it "calls the client synchronously" do
      Fullsend.track_event("course.started", email: "joe@gmail.com")

      expect(client).to have_received(:track_event).with("course.started", email: "joe@gmail.com")
    end
  end
end

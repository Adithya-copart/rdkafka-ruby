require "spec_helper"

describe Rdkafka::Producer do
  let(:producer) { rdkafka_config.producer }

  after do
    # Registry should always end up being empty
    expect(Rdkafka::Producer::DeliveryHandle::REGISTRY).to be_empty
  end

  it "should require a topic" do
    expect {
      producer.produce(
        payload: "payload",
        key:     "key"
     )
    }.to raise_error ArgumentError, "missing keyword: topic"
  end

  it "should produce a message" do
    # Produce a message
    handle = producer.produce(
      topic:   "produce_test_topic",
      payload: "payload",
      key:     "key"
    )

    # Should be pending at first
    expect(handle.pending?).to be true

    # Check delivery handle and report
    report = handle.wait(5)
    expect(handle.pending?).to be false
    expect(report).not_to be_nil
    expect(report.partition).to eq 1
    expect(report.offset).to be >= 0

    # Close producer
    producer.close

    # Consume message and verify it's content
    message = wait_for_message(
      topic: "produce_test_topic",
      delivery_report: report
    )
    expect(message.partition).to eq 1
    expect(message.payload).to eq "payload"
    expect(message.key).to eq "key"
    # Since api.version.request is on by default we will get
    # the message creation timestamp if it's not set.
    expect(message.timestamp).to be > 1505069891557
  end

  it "should produce a message with a specified partition" do
    # Produce a message
    handle = producer.produce(
      topic:     "produce_test_topic",
      payload:   "payload partition",
      key:       "key partition",
      partition: 1
    )
    report = handle.wait(5)

    # Consume message and verify it's content
    message = wait_for_message(
      topic: "produce_test_topic",
      delivery_report: report
    )
    expect(message.partition).to eq 1
    expect(message.key).to eq "key partition"
  end

  it "should produce a message with utf-8 encoding" do
    handle = producer.produce(
      topic:   "produce_test_topic",
      payload: "Τη γλώσσα μου έδωσαν ελληνική",
      key:     "key utf8"
    )
    report = handle.wait(5)

    # Consume message and verify it's content
    message = wait_for_message(
      topic: "produce_test_topic",
      delivery_report: report
    )

    expect(message.partition).to eq 1
    expect(message.payload.force_encoding("utf-8")).to eq "Τη γλώσσα μου έδωσαν ελληνική"
    expect(message.key).to eq "key utf8"
  end

  it "should produce a message with a timestamp" do
    handle = producer.produce(
      topic:     "produce_test_topic",
      payload:   "payload timestamp",
      key:       "key timestamp",
      timestamp: 1505069646000
    )
    report = handle.wait(5)

    # Consume message and verify it's content
    message = wait_for_message(
      topic: "produce_test_topic",
      delivery_report: report
    )

    expect(message.partition).to eq 2
    expect(message.key).to eq "key timestamp"
    expect(message.timestamp).to eq 1505069646000
  end

  it "should produce a message with nil key" do
    handle = producer.produce(
      topic:   "produce_test_topic",
      payload: "payload no key"
    )
    report = handle.wait(5)

    # Consume message and verify it's content
    message = wait_for_message(
      topic: "produce_test_topic",
      delivery_report: report
    )

    expect(message.key).to be_nil
    expect(message.payload).to eq "payload no key"
  end

  it "should produce a message with nil payload" do
    handle = producer.produce(
      topic: "produce_test_topic",
      key:   "key no payload"
    )
    report = handle.wait(5)

    # Consume message and verify it's content
    message = wait_for_message(
      topic: "produce_test_topic",
      delivery_report: report
    )

    expect(message.key).to eq "key no payload"
    expect(message.payload).to be_nil
  end

  it "should produce message that aren't waited for and not crash" do
    5.times do
      200.times do
        producer.produce(
          topic:   "produce_test_topic",
          payload: "payload not waiting",
          key:     "key not waiting"
        )
      end

      # Allow some time for a GC run
      sleep 1
    end

    # Wait for the delivery notifications
    10.times do
      break if Rdkafka::Producer::DeliveryHandle::REGISTRY.empty?
      sleep 1
    end
  end

  it "should produce a message in a forked process" do
    # Fork, produce a message, send the report of a pipe and
    # wait for it in the main process.

    @reader, @writer = IO.pipe

    # Instantiate the producer here, so we use a forked version
    # of it and not a freshly created one.
    @producer = producer

    fork do
      @reader.close

      handle = @producer.produce(
        topic:   "produce_test_topic",
        payload: "payload",
        key:     "key"
      )

      report = handle.wait(5)
      producer.close

      report_json = JSON.generate(
        "partition" => report.partition,
        "offset" => report.offset
      )

      @writer.write(report_json)
    end

    @writer.close

    report_hash = JSON.parse(@reader.read)
    report = Rdkafka::Producer::DeliveryReport.new(
      report_hash["partition"],
      report_hash["offset"]
    )

    # Consume message and verify it's content
    message = wait_for_message(
      topic: "produce_test_topic",
      delivery_report: report
    )
    expect(message.partition).to eq 1
    expect(message.payload).to eq "payload"
    expect(message.key).to eq "key"
  end

  it "should raise an error when producing fails" do
    expect(Rdkafka::Bindings).to receive(:rd_kafka_producev).and_return(20)

    expect {
      producer.produce(
        topic:   "produce_test_topic",
        key:     "key error"
      )
    }.to raise_error Rdkafka::RdkafkaError
  end

  it "should raise a timeout error when waiting too long" do
    handle = producer.produce(
      topic:   "produce_test_topic",
      payload: "payload timeout",
      key:     "key timeout"
    )
    expect {
      handle.wait(0)
    }.to raise_error Rdkafka::Producer::DeliveryHandle::WaitTimeoutError

    # Waiting a second time should work
    handle.wait(5)
  end
end

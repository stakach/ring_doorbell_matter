require "spec"
require "../src/ring_doorbell_matter"

# Polls the block until it returns truthy, failing the spec on timeout.
def wait_until(timeout : Time::Span = 2.seconds, message : String = "condition not met in time", &)
  deadline = Time.instant + timeout
  until yield
    fail message if Time.instant > deadline
    sleep 5.milliseconds
  end
end

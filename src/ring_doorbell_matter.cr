# A Matter bridge exposing Ring doorbells as occupancy (motion) sensors with
# battery level reporting. A doorbell press triggers the motion sensor for a
# configurable hold time (default 30s).
module RingDoorbellMatter
  VERSION = "0.1.0"
end

require "matter"
require "ring_doorbell"
require "goban"
require "option_parser"
require "log"
require "file_utils"

require "./ring_doorbell_matter/controller"
require "./ring_doorbell_matter/matter"
require "./ring_doorbell_matter/cli"

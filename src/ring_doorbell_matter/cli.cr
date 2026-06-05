module RingDoorbellMatter::CLI
  Log = ::Log.for("ring_doorbell_matter.cli")

  DEFAULT_TOKEN_FILE   = "data/ring.token"
  DEFAULT_STORAGE_FILE = RingDoorbellMatter::Matter::STORAGE_FILE_DEFAULT

  DOORBELL_FETCH_RETRY = 15.seconds

  private struct Config
    property token_file : String
    property storage_file : String
    property motion_hold_seconds : Int32
    property battery_poll_seconds : Int32
    property? motion_triggers : Bool
    property log_level : String

    def initialize
      @token_file = ENV["RING_TOKEN_FILE"]? || DEFAULT_TOKEN_FILE
      @storage_file = ENV["MATTER_STORAGE_FILE"]? || DEFAULT_STORAGE_FILE
      @motion_hold_seconds = ENV["MOTION_HOLD"]?.try(&.to_i?) || 30
      @battery_poll_seconds = ENV["BATTERY_POLL"]?.try(&.to_i?) || 3600
      @motion_triggers = {"1", "true", "yes"}.includes?(ENV["MOTION_TRIGGERS"]?.try(&.downcase))
      @log_level = ENV["LOG_LEVEL"]? || "info"
    end
  end

  def self.run : Nil
    config = Config.new

    OptionParser.parse do |opts|
      opts.banner = "Usage: ring_doorbell_matter [options]"
      opts.on("--token-file=PATH", "Ring token/state file (default #{config.token_file})") { |value| config.token_file = value }
      opts.on("--storage=PATH", "Matter persistence storage path (default #{config.storage_file})") { |value| config.storage_file = value }
      opts.on("--motion-hold=SECONDS", "How long a press holds the motion sensor (default #{config.motion_hold_seconds})") do |value|
        parsed = value.to_i?
        raise OptionParser::InvalidOption.new("--motion-hold must be a positive integer") unless parsed && parsed > 0
        config.motion_hold_seconds = parsed
      end
      opts.on("--battery-poll=SECONDS", "Battery refresh interval (default #{config.battery_poll_seconds})") do |value|
        parsed = value.to_i?
        raise OptionParser::InvalidOption.new("--battery-poll must be a positive integer") unless parsed && parsed > 0
        config.battery_poll_seconds = parsed
      end
      opts.on("--motion-triggers", "Ring motion events (camera models) also trigger the sensor") { config.motion_triggers = true }
      opts.on("--log-level=LEVEL", "Log level: debug|info|warn|error (default #{config.log_level})") { |value| config.log_level = value.downcase }
      opts.on("-h", "--help", "Show help") do
        puts opts
        exit 0
      end
    end

    configure_logging(config.log_level)
    Log.info do
      "starting service token_file=#{config.token_file} storage=#{config.storage_file} " \
      "motion_hold=#{config.motion_hold_seconds}s battery_poll=#{config.battery_poll_seconds}s " \
      "motion_triggers=#{config.motion_triggers?}"
    end

    controller = RingDoorbellMatter::Controller.new(token_file: config.token_file)

    unless controller.authenticated?
      STDERR.puts "Ring token file #{config.token_file} has no login."
      STDERR.puts "Authenticate once with the ring_doorbell init example:"
      STDERR.puts "  crystal run lib/ring_doorbell/examples/init.cr -- #{config.token_file}"
      exit 2
    end

    doorbells = fetch_doorbells(controller)
    if doorbells.empty?
      STDERR.puts "No doorbells found on this Ring account — nothing to bridge."
      exit 2
    end
    doorbells.each_with_index do |bell, index|
      Log.info { "endpoint #{index + 1}: #{bell.name} (ring id #{bell.id}, battery #{bell.battery.inspect}%)" }
    end

    device = RingDoorbellMatter::Matter.new(
      controller,
      doorbells,
      storage_file: config.storage_file,
      hold_time: config.motion_hold_seconds.seconds,
      battery_poll: config.battery_poll_seconds.seconds,
      motion_triggers: config.motion_triggers?,
      port: 0
    )

    Process.on_terminate do
      device.shutdown!
    end

    device.start
    device.await_shutdown
  end

  # The doorbell list shapes the Matter endpoints, so it must be available
  # before the device starts — retry until the Ring cloud answers.
  private def self.fetch_doorbells(controller : Controller) : Array(Controller::DoorbellInfo)
    loop do
      return controller.doorbells
    rescue ex : RingDoorbell::AuthError
      STDERR.puts "Ring authentication failed: #{ex.message}"
      exit 2
    rescue ex : RingDoorbell::Error
      Log.warn { "could not fetch doorbells (#{ex.message}); retrying in #{DOORBELL_FETCH_RETRY.total_seconds.to_i}s" }
      sleep DOORBELL_FETCH_RETRY
    end
  end

  private def self.configure_logging(log_level : String) : Nil
    severity = case log_level
               when "debug" then ::Log::Severity::Debug
               when "warn"  then ::Log::Severity::Warn
               when "error" then ::Log::Severity::Error
               else
                 ::Log::Severity::Info
               end

    backend = ::Log::IOBackend.new
    ::Log.setup(severity, backend)
  end
end

# Matter device exposing each Ring doorbell as an occupancy (motion) sensor
# endpoint with battery reporting:
#
# - endpoint N: OccupancySensing (PIR) + PowerSource (battery) + Identify +
#   FixedLabel (the doorbell's Ring name)
# - a doorbell press sets occupancy for `hold_time` (default 30s); pressing
#   again extends the window
# - battery is polled every `battery_poll` (default 1h) — battery levels
#   change slowly and Ring rate-limits aggressively
#
# Endpoints are assigned to doorbells sorted by Ring device id, so they stay
# stable across restarts while the set of doorbells is unchanged.
class RingDoorbellMatter::Matter < ::Matter::Device::Base
  Log = ::Log.for("ring_doorbell_matter.matter")

  DEVICE_NAME          = "Ring Doorbell"
  STORAGE_FILE_DEFAULT = "data/ring_doorbell_matter_storage.json"

  # test vendor + product/discriminator offset from the sibling bridges
  # (oven = 0x0F01, TV = 0x0F02)
  VENDOR_ID      = ::Matter::SetupPayload.test_vendor_id
  PRODUCT_ID     =     0x0F03_u16
  DISCRIMINATOR  =     0x0F03_u16
  SETUP_PIN_CODE = 20_202_021_u32

  DEFAULT_HOLD_TIME    = 30.seconds
  DEFAULT_BATTERY_POLL = 1.hour
  POLL_TICK            = 5.seconds
  LISTEN_RETRY_DELAY   = 15.seconds

  # Battery percentage thresholds for the Matter charge-level attribute.
  BATTERY_WARNING  = 20
  BATTERY_CRITICAL = 10

  # Everything attached to one doorbell's endpoint.
  private class Sensor
    getter info : RingDoorbellMatter::Controller::DoorbellInfo
    getter occupancy : ::Matter::Cluster::OccupancySensingCluster
    getter power : ::Matter::Cluster::PowerSourceCluster
    # Trigger generation — a new ding invalidates the previous clear timer.
    getter generation : Atomic(Int32) = Atomic(Int32).new(0)

    def initialize(@info, @occupancy, @power)
    end
  end

  @controller : RingDoorbellMatter::Controller::Control
  @doorbells : Array(RingDoorbellMatter::Controller::DoorbellInfo)
  @storage_file : String
  @hold_time : Time::Span
  @battery_poll : Time::Span
  @motion_triggers : Bool
  @running : Atomic(Bool) = Atomic(Bool).new(false)
  @listening : Atomic(Bool) = Atomic(Bool).new(false)
  @sensors : Hash(Int64, Sensor) = {} of Int64 => Sensor

  def initialize(
    @controller : RingDoorbellMatter::Controller::Control,
    doorbells : Array(RingDoorbellMatter::Controller::DoorbellInfo),
    @storage_file : String = STORAGE_FILE_DEFAULT,
    @hold_time : Time::Span = DEFAULT_HOLD_TIME,
    @battery_poll : Time::Span = DEFAULT_BATTERY_POLL,
    @motion_triggers : Bool = false,
    ip_addresses : Array(Socket::IPAddress)? = nil,
    port : Int32 = 0,
  )
    @doorbells = doorbells.sort_by(&.id)
    raise ArgumentError.new("at least one doorbell is required") if @doorbells.empty?

    super(ip_addresses: ip_addresses, port: port)

    @controller.on_ding { |device_id| trigger_motion(device_id, "ding") }
    @controller.on_motion do |device_id|
      trigger_motion(device_id, "motion") if @motion_triggers
    end
  end

  def device_name : String
    DEVICE_NAME
  end

  def vendor_id : UInt16
    VENDOR_ID
  end

  def product_id : UInt16
    PRODUCT_ID
  end

  def discriminator : UInt16
    DISCRIMINATOR
  end

  def setup_pin : UInt32
    SETUP_PIN_CODE
  end

  def primary_device_type_id : UInt16
    ::Matter::DeviceTypes::AGGREGATOR
  end

  def vendor_name : String
    "Ring Doorbell Bridge"
  end

  def product_name : String
    DEVICE_NAME
  end

  # The endpoint a doorbell is exposed on (1-based, doorbells sorted by id).
  def endpoint_for(device_id : Int64) : UInt16?
    index = @doorbells.index { |bell| bell.id == device_id }
    index.try { |i| (i + 1).to_u16 }
  end

  def occupancy_cluster(device_id : Int64) : ::Matter::Cluster::OccupancySensingCluster
    @sensors[device_id].occupancy
  end

  def power_cluster(device_id : Int64) : ::Matter::Cluster::PowerSourceCluster
    @sensors[device_id].power
  end

  # Pulls the current battery level for every doorbell into the PowerSource
  # clusters. Public so specs (and the poll loop) can drive it directly.
  def sync_battery(raise_on_error : Bool = false) : Nil
    @sensors.each_value do |sensor|
      level = @controller.battery_level(sensor.info.id)
      sensor.power.update_bat_percent_remaining(half_percent(level))
      sensor.power.update_bat_charge_level(charge_level(level))
      Log.debug { "battery sync: #{sensor.info.name} = #{level.inspect}%" }
    rescue ex
      raise ex if raise_on_error
      Log.warn(exception: ex) { "battery sync failed for #{sensor.info.name}" }
    end
  end

  protected def build_storage_manager : ::Matter::Storage::Manager
    directory = File.dirname(@storage_file)
    FileUtils.mkdir_p(directory) unless directory.empty?
    ::Matter::Storage::Manager.new(::Matter::Storage::JsonFileBackend.new(@storage_file))
  end

  protected def endpoint_device_types : Hash(UInt16, UInt32)
    types = {} of UInt16 => UInt32
    @doorbells.each_with_index do |_bell, index|
      types[(index + 1).to_u16] = ::Matter::DeviceTypes::OCCUPANCY_SENSOR.to_u32
    end
    types
  end

  protected def device_clusters : Array(::Matter::Cluster::Base)
    clusters = [] of ::Matter::Cluster::Base

    @doorbells.each_with_index do |bell, index|
      endpoint = ::Matter::DataType::EndpointNumber.new((index + 1).to_u16)

      occupancy = ::Matter::Cluster::OccupancySensingCluster.new(
        endpoint,
        hold_time: @hold_time.total_seconds.clamp(1, UInt16::MAX.to_f).to_u16,
      )

      power = ::Matter::Cluster::PowerSourceCluster.new(
        endpoint,
        description: "Battery",
        bat_percent_remaining: half_percent(bell.battery),
        bat_charge_level: charge_level(bell.battery),
        bat_replacement_needed: false,
        bat_replaceability: ::Matter::Cluster::PowerSourceCluster::BatReplaceability::UserReplaceable,
        bat_present: true,
      )

      clusters << occupancy.as(::Matter::Cluster::Base)
      clusters << power.as(::Matter::Cluster::Base)
      clusters << identify_cluster(endpoint).as(::Matter::Cluster::Base)
      clusters << label_cluster(endpoint, bell.name).as(::Matter::Cluster::Base)

      @sensors[bell.id] = Sensor.new(bell, occupancy, power)
    end

    clusters
  end

  protected def before_start : Nil
    interfaces = ip_addresses.map { |ip| "#{ip.address}(#{ip.family == Socket::Family::INET ? "v4" : "v6"})" }.join(", ")
    Log.info { "before_start: mdns interfaces=#{interfaces}" }
    Log.info { "before_start: deferring Ring push listener until commissioned; Matter UDP port=#{port}" }
  end

  protected def started_commissioning_mode : Nil
    Log.info { "device entered commissioning mode" }
    puts "Starting in Commissioning Mode"
    puts "The device is ready to be paired with a Matter controller."
    puts ""
    puts "mDNS Advertisement Active:"
    puts "  Service: _matterc._udp.local"
    puts "  Instance: #{responder.commissioning_instance_name || "<pending>"}"
    puts "  Hostname: #{hostname}"
    puts "  Port: #{port}"
    puts "  Discriminator: #{discriminator}"
    puts ""

    print_qr_code

    manual_code = setup_code
    puts "QR payload: #{qr_code_payload}"
    puts "Setup PIN: #{setup_pin}"
    puts "Manual pairing code: #{manual_code}"
    puts "chip-tool pairing command:"
    puts "  chip-tool pairing code 1 #{manual_code}"
    puts ""
  end

  protected def started_operational_mode : Nil
    Log.info { "device entered operational mode fabrics=#{fabric_table.size}" }
    puts "Starting in Operational Mode"
    puts "The device is commissioned and ready for use."
    puts ""

    fabric_table.all_fabrics.each do |fabric|
      puts "Operational Advertisement (Fabric #{fabric.fabric_index}):"
      puts "  Service: _matter._tcp.local"
      puts "  Fabric ID: 0x#{fabric.fabric_id.to_s(16).upcase}"
      puts "  Node ID: 0x#{fabric.node_id.to_s(16).upcase}"
      puts ""
    end
  end

  protected def on_started : Nil
    Log.info { "on_started: starting poll loop (battery every #{@battery_poll.total_minutes.to_i}m)" }
    @running.set(true)
    spawn { poll_loop }
  end

  protected def on_shutdown : Nil
    Log.info { "on_shutdown: stopping poll loop and push listener" }
    @running.set(false)
    stop_listener
  end

  protected def default_ip_addresses : Array(Socket::IPAddress)
    ips = [] of Socket::IPAddress

    begin
      socket = UDPSocket.new(:inet6)
      socket.connect("2606:4700:4700::1111", 53)
      addr = socket.local_address
      socket.close
      ips << Socket::IPAddress.new(addr.address, 0)
    rescue
    end

    begin
      socket = UDPSocket.new(:inet)
      socket.connect("8.8.8.8", 80)
      addr = socket.local_address
      socket.close
      ips << Socket::IPAddress.new(addr.address, 0)
    rescue
    end

    ips << Socket::IPAddress.new("127.0.0.1", 0) if ips.empty?
    ips
  end

  # ----- motion handling -----

  # Marks the doorbell's sensor occupied and schedules the clear. Another
  # trigger within the hold window extends it (the generation moves on, so
  # the older clear timer becomes a no-op).
  private def trigger_motion(device_id : Int64?, source : String) : Nil
    sensor = resolve_sensor(device_id)
    unless sensor
      Log.debug { "#{source} for unknown doorbell #{device_id.inspect} ignored" }
      return
    end

    Log.info { "#{source} at #{sensor.info.name} — motion for #{@hold_time.total_seconds.to_i}s" }
    sensor.occupancy.update_occupancy(true)
    generation = sensor.generation.add(1) + 1

    spawn do
      sleep @hold_time
      if sensor.generation.get == generation
        sensor.occupancy.update_occupancy(false)
        Log.debug { "motion cleared at #{sensor.info.name}" }
      end
    end
  end

  private def resolve_sensor(device_id : Int64?) : Sensor?
    if device_id
      @sensors[device_id]?
    elsif @sensors.size == 1
      # Pushes without a device id can only mean the sole doorbell.
      @sensors.first_value
    end
  end

  # ----- background sync -----

  private def poll_loop : Nil
    Log.info { "poll loop started" }
    waiting_for_commissioning = false
    next_battery_sync = Time.instant

    while @running.get
      begin
        if fabric_table.empty?
          unless waiting_for_commissioning
            Log.info { "poll loop: waiting for commissioning before contacting Ring" }
            waiting_for_commissioning = true
          end
          stop_listener
          sleep POLL_TICK
          next
        end

        if waiting_for_commissioning
          Log.info { "poll loop: commissioning complete; starting Ring push listener" }
          waiting_for_commissioning = false
        end

        unless @listening.get
          @controller.listen
          @listening.set(true)
          Log.info { "poll loop: push listener running" }
          next_battery_sync = Time.instant
        end

        if Time.instant >= next_battery_sync
          sync_battery(raise_on_error: true)
          next_battery_sync = Time.instant + @battery_poll
        end

        sleep POLL_TICK
      rescue ex
        Log.warn(exception: ex) { "poll loop: Ring sync failed; retrying in #{LISTEN_RETRY_DELAY.total_seconds.to_i}s" }
        stop_listener
        sleep LISTEN_RETRY_DELAY
      end
    end
    Log.info { "poll loop exited" }
  end

  private def stop_listener : Nil
    return unless @listening.get
    @controller.stop
    @listening.set(false)
  rescue ex
    Log.warn(exception: ex) { "stopping push listener failed" }
    @listening.set(false)
  end

  # ----- battery helpers -----

  # Matter reports battery in 0-200 half-percent units.
  private def half_percent(level : Int32?) : UInt8?
    level.try { |value| (value.clamp(0, 100) * 2).to_u8 }
  end

  private def charge_level(level : Int32?) : ::Matter::Cluster::PowerSourceCluster::BatChargeLevel
    case level
    when nil                   then ::Matter::Cluster::PowerSourceCluster::BatChargeLevel::Ok
    when .<=(BATTERY_CRITICAL) then ::Matter::Cluster::PowerSourceCluster::BatChargeLevel::Critical
    when .<=(BATTERY_WARNING)  then ::Matter::Cluster::PowerSourceCluster::BatChargeLevel::Warning
    else                            ::Matter::Cluster::PowerSourceCluster::BatChargeLevel::Ok
    end
  end

  # ----- endpoint construction helpers -----

  private def identify_cluster(endpoint : ::Matter::DataType::EndpointNumber) : ::Matter::Cluster::IdentifyCluster
    ::Matter::Cluster::IdentifyCluster.new(
      endpoint,
      identify_type: ::Matter::Cluster::IdentifyCluster::IdentifyType::None
    )
  end

  private def label_cluster(endpoint : ::Matter::DataType::EndpointNumber, label : String) : ::Matter::Cluster::FixedLabelCluster
    ::Matter::Cluster::FixedLabelCluster.new(
      endpoint,
      [::Matter::Cluster::LabelStruct.new("name", label)]
    )
  end

  # ----- pairing helpers -----

  private def setup_code : String
    ::Matter::SetupPayload.generate_manual_code(discriminator, setup_pin)
  end

  private def qr_code_payload : String
    ::Matter::SetupPayload::QRCode.generate_qr_code(
      discriminator: discriminator,
      pin: setup_pin,
      vendor_id: vendor_id,
      product_id: product_id,
      flow: ::Matter::SetupPayload::QRCode::CommissionFlow::Standard,
      capabilities: ::Matter::SetupPayload::QRCode::DiscoveryCapability::BLE
    )
  end

  private def print_qr_code : Nil
    payload = qr_code_payload
    qr = Goban::QR.encode_string(payload, Goban::ECC::Level::Low)
    puts "Scan this QR code with your Matter controller app:"
    puts ""
    qr.print_to_console
    puts ""
  rescue ex
    puts "Failed to generate QR code: #{ex.message}"
  end
end

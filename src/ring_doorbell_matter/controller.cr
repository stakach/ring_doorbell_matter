class RingDoorbellMatter::Controller
  Log = ::Log.for("ring_doorbell_matter.controller")

  # Static facts about a doorbell, captured when the bridge starts.
  record DoorbellInfo, id : Int64, name : String, battery : Int32?

  # The minimal control surface the Matter device drives. Specs implement
  # this with a fake so sensor wiring can be tested without a Ring account.
  module Control
    # The account's doorbells (Ring cloud REST).
    abstract def doorbells : Array(DoorbellInfo)
    # Freshest battery percentage for a doorbell (health endpoint).
    abstract def battery_level(id : Int64) : Int32?
    # Start the real-time push listener (idempotent; reconnects internally).
    abstract def listen : Nil
    abstract def stop : Nil
    # A doorbell press / buzz; the id may be nil if the push lacked one.
    abstract def on_ding(&block : Int64? -> Nil)
    # A Ring motion event (camera models only).
    abstract def on_motion(&block : Int64? -> Nil)
  end

  include Control

  @client : RingDoorbell::Client

  def initialize(*, token_file : String)
    directory = File.dirname(token_file)
    FileUtils.mkdir_p(directory) unless directory.empty?

    @client = RingDoorbell::Client.new(token_file: token_file)
  end

  def authenticated? : Bool
    @client.authenticated?
  end

  def doorbells : Array(DoorbellInfo)
    @client.doorbells.map do |bell|
      DoorbellInfo.new(
        id: bell.id,
        name: bell.name || "Doorbell #{bell.id}",
        battery: bell.battery_level,
      )
    end
  end

  def battery_level(id : Int64) : Int32?
    @client.battery_level(id)
  end

  # Starts the FCM push listener. The first call registers push credentials
  # with Google/Ring, which can take a few seconds.
  def listen : Nil
    @client.listen
  end

  def stop : Nil
    @client.stop
  end

  def on_ding(&block : Int64? -> Nil) : Nil
    @client.on_ding { |event| block.call(event.device_id) }
  end

  def on_motion(&block : Int64? -> Nil) : Nil
    @client.on_motion { |event| block.call(event.device_id) }
  end
end

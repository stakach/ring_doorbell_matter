require "./spec_helper"

private alias DoorbellInfo = RingDoorbellMatter::Controller::DoorbellInfo

private class FakeRingControl
  include RingDoorbellMatter::Controller::Control

  property doorbell_list : Array(DoorbellInfo) = [
    DoorbellInfo.new(id: 111_i64, name: "Front Entrance", battery: 62),
  ]
  property batteries : Hash(Int64, Int32?) = {111_i64 => 62.as(Int32?)}
  getter listen_calls : Int32 = 0
  getter stop_calls : Int32 = 0

  @ding_handler : Proc(Int64?, Nil)?
  @motion_handler : Proc(Int64?, Nil)?

  def doorbells : Array(DoorbellInfo)
    @doorbell_list
  end

  def battery_level(id : Int64) : Int32?
    @batteries[id]?
  end

  def listen : Nil
    @listen_calls += 1
  end

  def stop : Nil
    @stop_calls += 1
  end

  def on_ding(&block : Int64? -> Nil) : Nil
    @ding_handler = block
  end

  def on_motion(&block : Int64? -> Nil) : Nil
    @motion_handler = block
  end

  # --- spec drivers ---

  def press(id : Int64?) : Nil
    @ding_handler.try &.call(id)
  end

  def move(id : Int64?) : Nil
    @motion_handler.try &.call(id)
  end
end

private def build_device(control : FakeRingControl, storage_file : String, *,
                         hold_time : Time::Span = 80.milliseconds,
                         motion_triggers : Bool = false) : RingDoorbellMatter::Matter
  File.delete?(storage_file)
  RingDoorbellMatter::Matter.new(
    control,
    control.doorbell_list,
    storage_file: storage_file,
    hold_time: hold_time,
    motion_triggers: motion_triggers,
    port: 0,
  )
end

describe RingDoorbellMatter::Matter do
  it "triggers motion on a ding and clears it after the hold time" do
    control = FakeRingControl.new
    device = build_device(control, "/tmp/spec_ring_motion_storage.json")
    sensor = device.occupancy_cluster(111)

    sensor.occupied?.should be_false
    control.press(111)
    sensor.occupied?.should be_true

    wait_until { sensor.occupied? == false }
  end

  it "extends the motion window when pressed again inside it" do
    control = FakeRingControl.new
    device = build_device(control, "/tmp/spec_ring_extend_storage.json", hold_time: 120.milliseconds)
    sensor = device.occupancy_cluster(111)

    control.press(111)
    sleep 70.milliseconds
    control.press(111) # re-trigger inside the window

    # past the first deadline, still occupied because of the second press
    sleep 80.milliseconds
    sensor.occupied?.should be_true

    wait_until { sensor.occupied? == false }
  end

  it "maps each doorbell to its own endpoint and sensor" do
    control = FakeRingControl.new
    control.doorbell_list = [
      DoorbellInfo.new(id: 222_i64, name: "Back Door", battery: 90),
      DoorbellInfo.new(id: 111_i64, name: "Front Entrance", battery: 62),
    ]
    device = build_device(control, "/tmp/spec_ring_multi_storage.json")

    # endpoints assigned sorted by ring id
    device.endpoint_for(111).should eq(1_u16)
    device.endpoint_for(222).should eq(2_u16)
    device.endpoint_for(999).should be_nil

    control.press(222)
    device.occupancy_cluster(222).occupied?.should be_true
    device.occupancy_cluster(111).occupied?.should be_false
  end

  it "routes id-less pushes to the only doorbell, and ignores unknown ids" do
    control = FakeRingControl.new
    device = build_device(control, "/tmp/spec_ring_nilid_storage.json")
    sensor = device.occupancy_cluster(111)

    control.press(999) # unknown — must not raise or trigger
    sensor.occupied?.should be_false

    control.press(nil) # only one doorbell — assume it
    sensor.occupied?.should be_true
  end

  it "ignores motion events unless motion_triggers is enabled" do
    control = FakeRingControl.new
    device = build_device(control, "/tmp/spec_ring_motionoff_storage.json")
    control.move(111)
    device.occupancy_cluster(111).occupied?.should be_false

    control2 = FakeRingControl.new
    device2 = build_device(control2, "/tmp/spec_ring_motionon_storage.json", motion_triggers: true)
    control2.move(111)
    device2.occupancy_cluster(111).occupied?.should be_true
  end

  it "seeds the power source cluster from the initial battery reading" do
    control = FakeRingControl.new
    device = build_device(control, "/tmp/spec_ring_batinit_storage.json")
    power = device.power_cluster(111)

    power.bat_percent_remaining.should eq(124_u8) # 62% in half-percent units
    power.bat_charge_level.should eq(::Matter::Cluster::PowerSourceCluster::BatChargeLevel::Ok)
  end

  it "syncs battery level and charge thresholds" do
    control = FakeRingControl.new
    device = build_device(control, "/tmp/spec_ring_batsync_storage.json")
    power = device.power_cluster(111)

    control.batteries[111_i64] = 15
    device.sync_battery
    power.bat_percent_remaining.should eq(30_u8)
    power.bat_charge_level.should eq(::Matter::Cluster::PowerSourceCluster::BatChargeLevel::Warning)

    control.batteries[111_i64] = 8
    device.sync_battery
    power.bat_percent_remaining.should eq(16_u8)
    power.bat_charge_level.should eq(::Matter::Cluster::PowerSourceCluster::BatChargeLevel::Critical)

    control.batteries[111_i64] = nil
    device.sync_battery
    power.bat_percent_remaining.should be_nil
    power.bat_charge_level.should eq(::Matter::Cluster::PowerSourceCluster::BatChargeLevel::Ok)
  end

  it "exposes occupancy sensor endpoints with the doorbell's name" do
    control = FakeRingControl.new
    device = build_device(control, "/tmp/spec_ring_labels_storage.json")
    device.endpoint_for(111).should eq(1_u16)
    # the occupancy cluster carries the configured hold time (whole seconds, min 1)
    device.occupancy_cluster(111).hold_time.should eq(1_u16)
  end
end

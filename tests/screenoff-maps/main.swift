var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String) {precondition(value(),message);checks+=1}
func testPacket(_ f:MapGeo.Frame,_ x:Double,_ y:Double)->Data {
    var colors=[UInt8](repeating:0,count:1200*1200)
    for row in 0..<1200 {for col in 580..<620 {colors[row*1200+col]=1}}
    return MapGeo.encodeRaster(frameId:f.id,x0:Int(x-1200),y0:Int(y+1200),w:1200,h:1200,mmPerPx:2000,idx:colors)
}
func pump(_ seconds:Double = 0.1) {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
let f=MapGeo.Frame(refLat:30.5,refLng:104,id:789)
let plan=try RouteMapPlan([(x:0,y:0),(x:0,y:12000)])
let cache=RouteMapCache.shared,ble=BleLink.shared
defer {try? FileManager.default.removeItem(at:TestEnvironment.root)}
for y in stride(from:0.0,through:2400.0,by:600) {
    let node=RouteMapPlan.Node(x:0,y:y,distance:y)
    try cache.store(testPacket(f,0,y),frame:f,source:3,node:node,style:1)
}
let feeder=MapFeeder();feeder.frame=f
feeder.offlineMaps=RouteOfflineMaps(frame:f,plan:plan,source:3,buildings:false,foregroundBusy:{false},onReady:{_ in},onStatus:{_ in})
UIApplication.shared.applicationState = .background
feeder.setRenderingAvailable(false)
feeder.onLocation(lat:f.lat(0),lng:f.lng(0),bearing:0,kmh:120)
check(ble.packets.last?.type==3,"Background starts from an existing cached road packet")
check(feeder.chunkCy==0,"Initial cache uses actual packet centre")
feeder.onAck(type:3,id:feeder.chunkId)
feeder.lastFetchFail=Date();feeder.fetching=true
feeder.onLocation(lat:f.lat(300),lng:f.lng(0),bearing:0,kmh:120)
check(feeder.chunkCy==600,"Locked cached handoff bypasses both in-flight graphics and 15-second failure backoff")
check(!feeder.fetching && AmapSdkRaster.captures==0,"Locked cache read never dispatches a new graphics capture")
feeder.onAck(type:3,id:feeder.chunkId)
let count=ble.packets.count,serial=feeder.requestSerial,lastFailure=feeder.lastFetchFail
feeder.onLocation(lat:f.lat(5000),lng:f.lng(0),bearing:0,kmh:120)
pump()
check(ble.packets.count==count,"A locked cache miss never publishes an empty replacement")
check(feeder.chunkCy==600,"Missing area preserves the old map buffer")
check(feeder.lastFetchFail==lastFailure && feeder.requestSerial==serial,"Cache miss does not poison or restart a graphics failure timer")
let missing=plan.nodes[plan.displayTarget(progress:5000,x:0,y:5000,kmh:120)]
try cache.store(testPacket(f,missing.x,missing.y),frame:f,source:3,node:missing,style:1)
feeder.onLocation(lat:f.lat(5000),lng:f.lng(0),bearing:0,kmh:120)
check(feeder.chunkCy==missing.y,"A newly available cache packet is deliverable immediately after the miss")
feeder.onAck(type:3,id:feeder.chunkId)
let shifted=try RouteMapPlan([(x:100,y:100),(x:100,y:12100)])
feeder.offlineMaps=RouteOfflineMaps(frame:f,plan:shifted,source:3,buildings:false,foregroundBusy:{false},onReady:{_ in},onStatus:{_ in})
feeder.routeProgress = -1
feeder.onLocation(lat:f.lat(1100),lng:f.lng(100),bearing:0,kmh:120)
check(feeder.chunkCx==0 && feeder.chunkCy==1200,"Background reroute reuses an overlapping map instead of requiring identical new-route nodes")
check(AmapSdkRaster.captures==0,"All locked movement and reroute cases remain graphics-free")
check(cache.covering(frame:f,source:3,style:0,x:0,y:0,kmh:120)==nil,"Cache coverage never crosses a map style")
check(cache.covering(frame:f,source:1,style:1,x:0,y:0,kmh:120)==nil,"Cache coverage never crosses a provider")
let other=MapGeo.Frame(refLat:30.5,refLng:104,id:790)
check(cache.covering(frame:other,source:3,style:1,x:0,y:0,kmh:120)==nil,"Cache coverage never crosses a frame")
feeder.offlineMaps?.close();feeder.offlineMaps=nil
feeder.lastFetchFail = .distantPast
UIApplication.shared.applicationState = .active;feeder.setRenderingAvailable(true)
feeder.onLocation(lat:f.lat(9000),lng:f.lng(0),bearing:0,kmh:0)
for _ in 0..<20 {pump();if !feeder.fetching {break}}
check(AmapSdkRaster.captures==1,"Returning to foreground resumes missing-area graphics exactly once")
check(feeder.haveChunk,"Foreground still produces a normal map")
let first=RouteMapPreparationPolicy.next(base:[true,true,true,true,false],complete:[false,false,false,false,false],display:0,target:1,buildings:true,kmh:120,available:[true,true,true,true,true])
check(first?.index==4 && first?.buildings==false,"Distant route roads prepare before optional nearby roofs for screen-off use")
let roofs=RouteMapPreparationPolicy.next(base:[true,true,true],complete:[false,false,false],display:0,target:1,buildings:true,kmh:120,available:[true,true,true])
check(roofs?.buildings==true,"Building preparation remains enabled once all route roads are ready")
// Reproduce the real trace: a complete future packet was compacted before it
// covered the view, forcing base + roof delivery at every later handoff.
Settings.shared.buildings=true
func roofPacket(_ y:Double)->Data {
    var colors=[UInt8](repeating:0,count:1200*1200)
    for row in 0..<1200 {for col in 580..<620 {colors[row*1200+col]=1}}
    for row in 100..<150 {for col in 100..<150 {colors[row*1200+col]=4}}
    return MapGeo.encodeRaster(frameId:f.id,x0:-1200,y0:Int(y+1200),w:1200,h:1200,mmPerPx:2000|RasterPacket.flag,idx:colors)
}
let detailed=roofPacket(600)
check(RasterPacket.isBuilding(detailed) && !RasterPacket.isBuilding(detailed.prefix(15)),"Header-only flag probe retains short packet safety")
var wrapped=Data([7,8,9]);wrapped.append(detailed)
check(RasterPacket.isBuilding(wrapped.dropFirst(3)),"Header-only flag probe supports nonzero-index Data slices")
for fast in [true,false] {
    let staged=MapFeeder();staged.frame=f;staged.pose=(0,0,120)
    ble.mapBytesPerSecond=fast ? 1_000_000:1000
    staged.acceptChunk(testPacket(f,0,0),cx:0,cy:0,sat:false,type:3,info:"test base",src:3)
    staged.onAck(type:3,id:staged.chunkId)
    let before=ble.packets.count
    staged.acceptChunk(detailed,cx:0,cy:600,sat:false,type:3,info:"prepared complete",src:3)
    check(ble.packets.count==before,"A future map waits until it covers the viewport")
    check(staged.handoff.pending.map{RasterPacket.isBuilding($0.bytes)} == true,"Future stage retains its complete cached roofs")
    staged.pose=(0,300,120);staged.flushPreparedMap()
    check(ble.packets.count==before+1,"Ready handoff issues one packet")
    check(RasterPacket.isBuilding(ble.packets.last!.bytes)==fast,fast ? "Measured roomy window delivers cached roads and roofs together":"Tight delivery window still compacts to roads before sending")
    if fast {
        staged.onAck(type:3,id:staged.chunkId);staged.tryUpgradeBuildings()
        check(ble.packets.count==before+1,"Complete handoff does not trigger a redundant second roof transfer")
    } else {
        check(staged.deferredRoofs != nil,"Tight-window roads keep roofs available for a later safe upgrade")
    }
}
// Admission must reserve the same road budget as protection after issue. This
// boundary passed the old check and was immediately cancelled on the next fix.
let reserved=MapFeeder();reserved.frame=f;reserved.pose=(0,0,120)
ble.mapBytesPerSecond=1_000_000
reserved.acceptChunk(testPacket(f,0,0),cx:0,cy:0,sat:false,type:3,info:"reserve base",src:3)
reserved.onAck(type:3,id:reserved.chunkId);reserved.pose=(0,300,120)
let room=MapCoveragePolicy.remainingSeconds(x:0,y:300,cx:0,cy:0,kmh:120,bearing:nil)
let oldRoadCount=MapDeliveryPolicy.compactBase(reserved.chunkBytes!).count
ble.mapBytesPerSecond=(Double(detailed.count)+Double(oldRoadCount)*0.5)/max(0.1,room-1)
check(!reserved.roofDeliveryAllowed(detailed,cx:0,cy:600),"A new-centre full map cannot omit the road reserve then cancel immediately")
ble.mapBytesPerSecond=Double(detailed.count+oldRoadCount)/max(0.1,room-1)*1.5
check(reserved.roofDeliveryAllowed(detailed,cx:0,cy:600),"A genuinely sufficient window still permits one complete map")
reserved.acceptChunk(detailed,cx:0,cy:600,sat:false,type:3,info:"complete with reserve",src:3)
check(reserved.chunkBuildingsComplete && reserved.upgradeBase != nil,"Complete map is in flight with the real previous base saved")
ble.mapRemaining=detailed.count
let yieldBefore=MapPipelineTrace.names.filter{$0=="roof-yield"}.count
reserved.protectBaseDuringRoofTransfer()
check(reserved.chunkCy==600 && MapPipelineTrace.names.filter{$0=="roof-yield"}.count==yieldBefore,"Unchanged position/rate cannot immediately revoke an admitted transfer")
reserved.pose=(0,350,120);reserved.protectBaseDuringRoofTransfer()
check(reserved.chunkCy==0 && reserved.chunkAcked && MapPipelineTrace.names.filter{$0=="roof-yield"}.count==yieldBefore+1,"Actual loss of the delivery window still yields and restores the confirmed base")
check(reserved.chunkRoadBytes==oldRoadCount,"Yield restores the saved road reservation alongside the original map")
ble.mapRemaining=0
Settings.shared.buildings=false;ble.mapBytesPerSecond=30000
print("PASS screen-off production feeder/cache: \(checks) checks; locked handoff, cache misses, recent failure, busy capture, reroute overlap, source/style/frame isolation and foreground recovery")

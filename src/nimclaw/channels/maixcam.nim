import chronos
import chronos/transports/stream
import std/[json, tables, strutils, locks]
import base
import ../bus, ../bus_types, ../config, ../logger

type
  MaixCamChannel* = ref object of BaseChannel
    server: StreamServer
    clients: seq[StreamTransport]
    lock: Lock
    host: string
    port: int

proc newMaixCamChannel*(cfg: MaixCamConfig, bus: MessageBus): MaixCamChannel =
  let base = newBaseChannel("maixcam", bus, cfg.allow_from)
  var mc = MaixCamChannel(
    bus: base.bus,
    name: base.name,
    allowList: base.allowList,
    running: false,
    clients: @[],
    host: cfg.host,
    port: cfg.port
  )
  initLock(mc.lock)
  return mc

method name*(c: MaixCamChannel): string = "maixcam"

proc handleClient(c: MaixCamChannel, transp: StreamTransport) {.async.} =
  var reader = newAsyncStreamReader(transp)
  defer: await reader.closeWait()
  
  while c.running:
    try:
      let line = await reader.readLine()
      if line.len == 0: break
      let msg = parseJson(line)
      let msgType = msg.getOrDefault("type").getStr()

      case msgType:
      of "person_detected":
        let data = msg["data"]
        let score = data.getOrDefault("score").getFloat()
        let x = data.getOrDefault("x").getFloat()
        let y = data.getOrDefault("y").getFloat()
        let w = data.getOrDefault("w").getFloat()
        let h = data.getOrDefault("h").getFloat()
        let className = data.getOrDefault("class_name").getStr("person")

        let content = "📷 Person detected!\nClass: $1\nConfidence: $2%\nPosition: ($3, $4)\nSize: $5x$6".format(
          className, (score * 100).formatFloat(ffDecimal, 2), x, y, w, h
        )

        var metadata = initTable[string, string]()
        metadata["timestamp"] = $msg.getOrDefault("timestamp").getFloat()
        metadata["score"] = $score

        c.handleMessage("maixcam", "default", content, @[], metadata)

      of "heartbeat":
        debug( "Received heartbeat", topic = "maixcam")
      of "status":
        info( "Status update from MaixCam", topic = "maixcam", status = $msg["data"])
      else:
        warn( "Unknown message type", topic = "maixcam", `type` = msgType)

    except CatchableError as e:
      error( "Failed to handle client", topic = "maixcam", error = e.msg)
      break

  acquire(c.lock)
  let idx = c.clients.find(transp)
  if idx != -1: c.clients.delete(idx)
  release(c.lock)
  await transp.closeWait()

proc onAccept(server: StreamServer, transp: StreamTransport) {.async.} =
  let c = cast[MaixCamChannel](server.udata)
  if c == nil or not c.running:
    await transp.closeWait()
    return
  acquire(c.lock)
  c.clients.add(transp)
  release(c.lock)
  discard handleClient(c, transp)

method start*(c: MaixCamChannel) {.async.} =
  info("Starting MaixCam channel server", topic = "maixcam")
  try:
    let address = initTAddress(c.host, c.port)
    c.server = createStreamServer(address, onAccept, {ReuseAddr}, udata = cast[pointer](c))
    c.server.start()
    c.running = true
    info("MaixCam server listening", topic = "maixcam", host = c.host, port = $c.port)
  except CatchableError as e:
    error("Failed to start MaixCam server", topic = "maixcam", error = e.msg)

method stop*(c: MaixCamChannel) {.async.} =
  c.running = false
  if c.server != nil:
    c.server.stop()
    c.server = nil
  acquire(c.lock)
  for client in c.clients:
    try: await client.closeWait()
    except: discard
  c.clients = @[]
  release(c.lock)

method send*(c: MaixCamChannel, msg: OutboundMessage) {.async.} =
  if not c.running: return
  let payload = %*{"type": "command", "timestamp": 0.0, "message": msg.content, "chat_id": msg.chat_id}
  let data = $payload & "\n"
  acquire(c.lock)
  for client in c.clients:
    try: 
      var writer = newAsyncStreamWriter(client)
      await writer.write(data)
      await writer.finish()
      await writer.closeWait()
    except: discard
  release(c.lock)

method isRunning*(c: MaixCamChannel): bool = c.running

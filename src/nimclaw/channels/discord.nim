import chronos
import chronos/apps/http/httpclient
import std/[json, strutils, tables]
import system/memory
import websock/[websock, session, types]
import base
import ../bus, ../bus_types, ../config, ../logger, ../services/voice

type
  DiscordChannel* = ref object of BaseChannel
    token*: string
    ws*: WSSession
    transcriber*: GroqTranscriber
    session*: HttpSessionRef

proc newDiscordChannel*(cfg: DiscordConfig, bus: MessageBus): DiscordChannel =
  let base = newBaseChannel("discord", bus, cfg.allow_from)
  DiscordChannel(
    bus: base.bus,
    name: base.name,
    allowList: base.allowList,
    running: false,
    token: cfg.token,
    session: HttpSessionRef.new()
  )

method setTranscriber*(c: DiscordChannel, transcriber: GroqTranscriber) =
  c.transcriber = transcriber

proc apiCall(c: DiscordChannel, method_name: string, url_part: string, payload: JsonNode = nil, meth: string = "POST"): Future[JsonNode] {.async.} =
  var headers: seq[HttpHeaderTuple] = @[
    (key: "Authorization", value: "Bot " & c.token),
    (key: "Content-Type", value: "application/json")
  ]
  let url = "https://discord.com/api/v10/" & url_part
  
  let addressRes = c.session.getAddress(url)
  if addressRes.isErr:
    return %*{}
  let address = addressRes.get()
  
  var bodyData: seq[byte] = @[]
  if payload != nil:
    let s = $payload
    bodyData = newSeq[byte](s.len)
    copyMem(addr bodyData[0], unsafeAddr s[0], s.len)
  let request = HttpClientRequestRef.new(
    c.session,
    address,
    meth = if meth == "GET": MethodGet else: MethodPost,
    headers = headers,
    body = bodyData
  )
  
  var response: HttpClientResponseRef = nil
  try:
    response = await request.send()
    let bodyBytes = await response.getBodyBytes()
    await response.closeWait()
    response = nil
    let body = cast[string](bodyBytes)
    if body == "": return %*{}
    return parseJson(body)
  except CatchableError:
    if not isNil(response):
      await response.closeWait()
    return %*{}

proc gatewayLoop(c: DiscordChannel) {.async.} =
  while c.running:
    try:
      let data = await c.ws.recvMsg()
      if data.len == 0: break
      let msg = parseJson(cast[string](data))
      let op = msg["op"].getInt()

      if op == 10: # Hello
        let interval = msg["d"]["heartbeat_interval"].getInt()
        # Start heartbeating (simplified)
        discard (proc() {.async.} =
          while c.running:
            await sleepAsync(interval)
            if c.ws != nil: await c.ws.send($ %*{"op": 1, "d": nil})
        )()
        # Identify
        await c.ws.send($ %*{
          "op": 2,
          "d": {
            "token": c.token,
            "intents": 33280, # GuildMessages | DirectMessages | MessageContent
            "properties": {"os": "linux", "browser": "nimclaw", "device": "nimclaw"}
          }
        })

      elif op == 0: # Dispatch
        let t = msg["t"].getStr()
        if t == "MESSAGE_CREATE":
          let d = msg["d"]
          if d.getOrDefault("author").getOrDefault("bot").getBool(): continue
          let senderID = d["author"]["id"].getStr()
          let chatID = d["channel_id"].getStr()
          let content = d["content"].getStr()
          c.handleMessage(senderID, chatID, content)

    except CatchableError as e:
      error( "Gateway error", topic = "discord", error = e.msg)
      await sleepAsync(5000)

method name*(c: DiscordChannel): string = "discord"

method start*(c: DiscordChannel) {.async.} =
  info( "Starting Discord bot (Gateway mode)...", topic = "discord")
  try:
    let gatewayRes = await c.apiCall("GET", "gateway/bot", meth="GET")
    let url = gatewayRes["url"].getStr()
    # Parse gateway URL
    var gatewayHost = url.replace("wss://", "").replace("ws://", "")
    var gatewayPath = "/?v=10&encoding=json"
    if gatewayHost.contains("/"):
      let parts = gatewayHost.split("/", 1)
      gatewayHost = parts[0]
      gatewayPath = "/" & parts[1] & gatewayPath
    
    c.ws = await WebSocket.connect(gatewayHost, gatewayPath, secure = true)
    c.running = true
    discard gatewayLoop(c)
  except CatchableError as e:
    error("Failed to start Discord bot", topic = "discord", error = e.msg)

method stop*(c: DiscordChannel) {.async.} =
  c.running = false
  if c.ws != nil: 
    try:
      await c.ws.close()
    except: discard
    c.ws = nil
  if c.session != nil:
    await c.session.closeWait()
    c.session = nil

method send*(c: DiscordChannel, msg: OutboundMessage) {.async.} =
  if not c.running: return
  discard await c.apiCall("POST", "channels/$1/messages".format(msg.chat_id), %*{"content": msg.content})

method isRunning*(c: DiscordChannel): bool = c.running

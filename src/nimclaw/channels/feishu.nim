import chronos
import chronos/apps/http/httpclient
import std/[json, strutils, tables]
import websock/websock
import base
import ../bus, ../bus_types, ../config, ../logger

type
  FeishuChannel* = ref object of BaseChannel
    appID: string
    appSecret: string
    token: string
    ws*: WSSession
    session*: HttpSessionRef

proc newFeishuChannel*(cfg: FeishuConfig, bus: MessageBus): FeishuChannel =
  let base = newBaseChannel("feishu", bus, cfg.allow_from)
  return FeishuChannel(
    bus: base.bus,
    name: base.name,
    allowList: base.allowList,
    running: false,
    appID: cfg.app_id,
    appSecret: cfg.app_secret,
    session: HttpSessionRef.new()
  )

proc getTenantAccessToken(c: FeishuChannel) {.async.} =
  let url = "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal"
  let payload = %*{"app_id": c.appID, "app_secret": c.appSecret}
  
  var headers: seq[HttpHeaderTuple] = @[
    (key: "Content-Type", value: "application/json")
  ]
  
  let addressRes = c.session.getAddress(url)
  if addressRes.isErr:
    return
  let address = addressRes.get()
  
  let bodyStr = $payload
  let request = HttpClientRequestRef.new(
    c.session,
    address,
    meth = MethodPost,
    headers = headers,
    body = bodyStr.toOpenArrayByte(0, bodyStr.len - 1)
  )
  
  var response: HttpClientResponseRef = nil
  try:
    response = await request.send()
    let bodyBytes = await response.getBodyBytes()
    await response.closeWait()
    response = nil
    let body = cast[string](bodyBytes)
    let res = parseJson(body)
    if res.hasKey("tenant_access_token"):
      c.token = res["tenant_access_token"].getStr()
      info( "Obtained Feishu tenant access token", topic = "feishu")
    else:
      error( "Failed to get token", topic = "feishu", response = body)
  except CatchableError as e:
    if not isNil(response):
      await response.closeWait()
    error("Auth error", topic = "feishu", error = e.msg)

proc feishuGatewayLoop(c: FeishuChannel) {.async.} =
  while c.running:
    try:
      if c.ws == nil:
        await sleepAsync(5000)
        continue
      let data = await c.ws.recvMsg()
      if data.len == 0: break
      let msg = parseJson(cast[string](data))

      # Handle Feishu WebSocket events
      if msg.hasKey("header") and msg["header"].hasKey("event_type"):
        let eventType = msg["header"]["event_type"].getStr()
        if eventType == "im.message.receive_v1":
          let event = msg["event"]
          let sender = event["sender"]
          let message = event["message"]

          let chatID = message["chat_id"].getStr()
          let senderID = if sender.hasKey("sender_id"):
                           sender["sender_id"].getOrDefault("open_id").getStr()
                         else: "unknown"

          var content = ""
          if message["msg_type"].getStr() == "text":
            let contentJson = parseJson(message["content"].getStr())
            content = contentJson["text"].getStr()
          else:
            content = "[Non-text message]"

          info("Received message", topic = "feishu", sender = senderID)
          c.handleMessage(senderID, chatID, content)

    except CatchableError as e:
      error("Gateway error", topic = "feishu", error = e.msg)
      await sleepAsync(5000)

method name*(c: FeishuChannel): string = "feishu"

method start*(c: FeishuChannel) {.async.} =
  if c.appID == "" or c.appSecret == "": return
  info("Starting Feishu channel (WS mode)...", topic = "feishu")
  await c.getTenantAccessToken()

  var headers: seq[HttpHeaderTuple] = @[
    (key: "Authorization", value: "Bearer " & c.token)
  ]
  
  let url = "https://open.feishu.cn/open-apis/ws/v1/endpoint"
  let addressRes = c.session.getAddress(url)
  if addressRes.isErr:
    c.running = true
    info("Feishu started in send-only mode (WS failed)", topic = "feishu")
    return
  let address = addressRes.get()
  
  let request = HttpClientRequestRef.new(
    c.session,
    address,
    meth = MethodPost,
    headers = headers
  )
  
  var response: HttpClientResponseRef = nil
  try:
    response = await request.send()
    let bodyBytes = await response.getBodyBytes()
    await response.closeWait()
    response = nil
    let body = cast[string](bodyBytes)
    let res = parseJson(body)
    if res.hasKey("data") and res["data"].hasKey("url"):
      let wsUrl = res["data"]["url"].getStr()
      # Parse WebSocket URL
      var wsHost = wsUrl.replace("wss://", "").replace("ws://", "")
      var wsPath = "/"
      if wsHost.contains("/"):
        let parts = wsHost.split("/", 1)
        wsHost = parts[0]
        wsPath = "/" & parts[1]
      
      c.ws = await WebSocket.connect(wsHost, wsPath, secure = wsUrl.startsWith("wss"))
      c.running = true
      discard feishuGatewayLoop(c)
      info("Feishu connected via WebSocket", topic = "feishu")
    else:
      c.running = true
      info("Feishu started in send-only mode (WS failed)", topic = "feishu")
  except CatchableError as e:
    if not isNil(response):
      await response.closeWait()
    error("WS handshake failed", topic = "feishu", error = e.msg)
    c.running = true

method stop*(c: FeishuChannel) {.async.} =
  c.running = false
  if c.ws != nil: 
    try:
      await c.ws.close()
    except: discard
    c.ws = nil
  if c.session != nil:
    await c.session.closeWait()
    c.session = nil

method send*(c: FeishuChannel, msg: OutboundMessage) {.async.} =
  if not c.running: return
  
  var headers: seq[HttpHeaderTuple] = @[
    (key: "Authorization", value: "Bearer " & c.token),
    (key: "Content-Type", value: "application/json")
  ]
  
  let url = "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id"
  let payload = %*{
    "receive_id": msg.chat_id,
    "msg_type": "text",
    "content": $ %*{"text": msg.content}
  }
  
  let addressRes = c.session.getAddress(url)
  if addressRes.isErr:
    return
  let address = addressRes.get()
  
  let bodyStr = $payload
  let request = HttpClientRequestRef.new(
    c.session,
    address,
    meth = MethodPost,
    headers = headers,
    body = bodyStr.toOpenArrayByte(0, bodyStr.len - 1)
  )
  
  var resp: HttpClientResponseRef = nil
  try:
    resp = await request.send()
    let status = resp.status
    let bodyBytes = await resp.getBodyBytes()
    await resp.closeWait()
    resp = nil
    if status != 200:
      error("Send failed", topic = "feishu", status = $status, response = cast[string](bodyBytes))
  except CatchableError as e:
    if not isNil(resp):
      await resp.closeWait()
    error("Send error", topic = "feishu", error = e.msg)

method isRunning*(c: FeishuChannel): bool = c.running

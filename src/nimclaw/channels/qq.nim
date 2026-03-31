import chronos
import chronos/apps/http/httpclient
import std/[json, strutils, tables, locks]
import websock/websock
import base
import ../bus, ../bus_types, ../config, ../logger

type
  QQChannel* = ref object of BaseChannel
    appID: string
    appSecret: string
    token: string
    ws*: WSSession
    processedIDs: Table[string, bool]
    lock: Lock
    session*: HttpSessionRef

proc newQQChannel*(cfg: QQConfig, bus: MessageBus): QQChannel =
  let base = newBaseChannel("qq", bus, cfg.allow_from)
  var qc = QQChannel(
    bus: base.bus,
    name: base.name,
    allowList: base.allowList,
    running: false,
    appID: cfg.app_id,
    appSecret: cfg.app_secret,
    processedIDs: initTable[string, bool](),
    session: HttpSessionRef.new()
  )
  initLock(qc.lock)
  return qc

proc getAccessToken(c: QQChannel) {.async.} =
  let url = "https://bots.qq.com/app/getAppAccessToken"
  let payload = %*{"appId": c.appID, "clientSecret": c.appSecret}
  
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
    if res.hasKey("access_token"):
      c.token = res["access_token"].getStr()
      infoC("qq", "Obtained QQ access token")
    else:
      errorCF("qq", "Failed to get access token", {"response": body}.toTable)
  except CatchableError as e:
    if not isNil(response):
      await response.closeWait()
    errorCF("qq", "Auth error", {"error": e.msg}.toTable)

proc qqGatewayLoop(c: QQChannel) {.async.} =
  while c.running:
    try:
      let data = await c.ws.recvMsg()
      if data.len == 0: break
      let msg = parseJson(cast[string](data))
      let op = msg["op"].getInt()

      if op == 10: # Hello
        let interval = msg["d"]["heartbeat_interval"].getInt()
        discard (proc() {.async.} =
          while c.running:
            await sleepAsync(interval)
            if c.ws != nil: await c.ws.send($ %*{"op": 1, "d": nil})
        )()
        # Identify
        await c.ws.send($ %*{
          "op": 2,
          "d": {
            "token": "QQBot " & c.token,
            "intents": 1 shl 30, # Intent for C2C and Group messages
            "properties": {"os": "linux", "browser": "nimclaw", "device": "nimclaw"}
          }
        })

      elif op == 0: # Dispatch
        let t = msg["t"].getStr()
        if t == "C2C_MESSAGE_CREATE" or t == "GROUP_AT_MESSAGE_CREATE":
          let d = msg["d"]
          let msgID = d["id"].getStr()

          acquire(c.lock)
          if c.processedIDs.hasKey(msgID):
            release(c.lock)
            continue
          c.processedIDs[msgID] = true
          release(c.lock)

          let senderID = if d.hasKey("author"): d["author"]["id"].getStr() else: "unknown"
          let content = d["content"].getStr()
          let chatID = if t == "C2C_MESSAGE_CREATE": senderID else: d["group_id"].getStr()

          infoCF("qq", "Received message", {"type": t, "sender": senderID}.toTable)
          c.handleMessage(senderID, chatID, content)

    except Exception as e:
      errorCF("qq", "Gateway error", {"error": e.msg}.toTable)
      await sleepAsync(5000)

method name*(c: QQChannel): string = "qq"

method start*(c: QQChannel) {.async.} =
  if c.appID == "" or c.appSecret == "": return
  infoC("qq", "Starting QQ Bot channel...")
  await c.getAccessToken()

  var headers: seq[HttpHeaderTuple] = @[
    (key: "Authorization", value: "QQBot " & c.token)
  ]
  
  let url = "https://api.sgroup.qq.com/gateway/bot"
  let addressRes = c.session.getAddress(url)
  if addressRes.isErr:
    errorCF("qq", "Failed to resolve gateway URL", initTable[string, string]())
    return
  let address = addressRes.get()
  
  let request = HttpClientRequestRef.new(
    c.session,
    address,
    meth = MethodGet,
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
    if res.hasKey("url"):
      let wsUrl = res["url"].getStr()
      # Parse WebSocket URL
      var wsHost = wsUrl.replace("wss://", "").replace("ws://", "")
      var wsPath = "/"
      if wsHost.contains("/"):
        let parts = wsHost.split("/", 1)
        wsHost = parts[0]
        wsPath = "/" & parts[1]
      
      c.ws = await WebSocket.connect(wsHost, wsPath, secure = wsUrl.startsWith("wss"))
      c.running = true
      discard qqGatewayLoop(c)
      infoC("qq", "QQ bot connected")
  except CatchableError as e:
    if not isNil(response):
      await response.closeWait()
    errorCF("qq", "Connection failed", {"error": e.msg}.toTable)

method stop*(c: QQChannel) {.async.} =
  c.running = false
  if c.ws != nil: 
    try:
      await c.ws.close()
    except: discard
    c.ws = nil
  if c.session != nil:
    await c.session.closeWait()
    c.session = nil

method send*(c: QQChannel, msg: OutboundMessage) {.async.} =
  if not c.running: return
  
  var headers: seq[HttpHeaderTuple] = @[
    (key: "Authorization", value: "QQBot " & c.token),
    (key: "Content-Type", value: "application/json")
  ]
  
  let url = "https://api.sgroup.qq.com/v2/users/$1/messages".format(msg.chat_id)
  let payload = %*{"content": msg.content, "msg_type": 0}
  
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
      errorCF("qq", "Send failed", {"status": $status, "response": cast[string](bodyBytes)}.toTable)
  except CatchableError as e:
    if not isNil(resp):
      await resp.closeWait()
    errorCF("qq", "Send error", {"error": e.msg}.toTable)

method isRunning*(c: QQChannel): bool = c.running

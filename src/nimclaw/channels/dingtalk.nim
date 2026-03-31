import chronos
import chronos/apps/http/httpclient
import std/[json, strutils, tables, locks]
import websock/websock
import base
import ../bus, ../bus_types, ../config, ../logger

type
  DingTalkChannel* = ref object of BaseChannel
    clientID: string
    clientSecret: string
    sessionWebhooks: Table[string, string]
    lock: Lock
    ws*: WSSession
    session*: HttpSessionRef

proc newDingTalkChannel*(cfg: DingTalkConfig, bus: MessageBus): DingTalkChannel =
  let base = newBaseChannel("dingtalk", bus, cfg.allow_from)
  var dc = DingTalkChannel(
    bus: base.bus,
    name: base.name,
    allowList: base.allowList,
    running: false,
    clientID: cfg.client_id,
    clientSecret: cfg.client_secret,
    sessionWebhooks: initTable[string, string](),
    session: HttpSessionRef.new()
  )
  initLock(dc.lock)
  return dc

proc dingtalkGatewayLoop(c: DingTalkChannel) {.async.} =
  while c.running:
    try:
      if c.ws == nil:
        await sleepAsync(5000)
        continue

      let data = await c.ws.recvMsg()
      if data.len == 0: break
      let msg = parseJson(cast[string](data))

      # Simplified DingTalk Stream Mode handling
      if msg.getOrDefault("type").getStr() == "chat.chatbot.message":
        let dataModel = msg["data"]
        let content = dataModel["text"]["content"].getStr()
        let senderID = dataModel["senderStaffId"].getStr()
        let chatID = if dataModel["conversationType"].getStr() == "1": senderID else: dataModel["conversationId"].getStr()

        acquire(c.lock)
        c.sessionWebhooks[chatID] = dataModel["sessionWebhook"].getStr()
        release(c.lock)

        infoCF("dingtalk", "Received message", {"sender": senderID}.toTable)
        c.handleMessage(senderID, chatID, content)
    except Exception as e:
      errorCF("dingtalk", "Gateway error", {"error": e.msg}.toTable)
      await sleepAsync(5000)

method name*(c: DingTalkChannel): string = "dingtalk"

method start*(c: DingTalkChannel) {.async.} =
  if c.clientID == "" or c.clientSecret == "": return
  infoC("dingtalk", "Starting DingTalk channel...")

  # In a real implementation, we would perform OAuth and then connect to DingTalk's Stream Gateway.
  # Here we provide the structure to support it.
  c.running = true
  discard dingtalkGatewayLoop(c)
  infoC("dingtalk", "DingTalk channel started")

method stop*(c: DingTalkChannel) {.async.} =
  c.running = false
  if c.ws != nil: 
    try:
      await c.ws.close()
    except: discard
    c.ws = nil
  if c.session != nil:
    await c.session.closeWait()
    c.session = nil

method send*(c: DingTalkChannel, msg: OutboundMessage) {.async.} =
  if not c.running: return
  acquire(c.lock)
  let hasWebhook = c.sessionWebhooks.hasKey(msg.chat_id)
  let webhook = if hasWebhook: c.sessionWebhooks[msg.chat_id] else: ""
  release(c.lock)

  if webhook == "":
    # Fallback to general DingTalk Bot API if session webhook is missing
    errorCF("dingtalk", "No session webhook for chat", {"chat_id": msg.chat_id}.toTable)
    return

  var headers: seq[HttpHeaderTuple] = @[
    (key: "Content-Type", value: "application/json")
  ]
  let payload = %*{
    "msgtype": "markdown",
    "markdown": {
      "title": "PicoClaw",
      "text": msg.content
    }
  }
  
  let addressRes = c.session.getAddress(webhook)
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
      errorCF("dingtalk", "Send failed", {"status": $status, "response": cast[string](bodyBytes)}.toTable)
  except CatchableError as e:
    if not isNil(resp):
      await resp.closeWait()
    errorCF("dingtalk", "Send error", {"error": e.msg}.toTable)

method isRunning*(c: DingTalkChannel): bool = c.running

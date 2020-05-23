import threadproxy, asyncdispatch

type
  WorkerThreadArgs = object
    multiplier: int
    token: ThreadToken

proc workerMain(args: WorkerThreadArgs) {.thread.} =
  let proxy = newThreadProxy(args.token)

  # register action handler
  proxy.onData "multiply":
    let x = data.getInt()
    return %(args.multiplier*x)

  # start processing channel
  waitFor proxy.poll()

proc main() =
  let proxy = newMainThreadProxy("master")
  asyncCheck proxy.poll()

  # create thread token
  let token = proxy.createToken("worker_0")

  var workerThread: Thread[WorkerThreadArgs]
  createThread(workerThread, workerMain, WorkerThreadArgs(
    multiplier: 3,
    token: token
  ))


  # ask worker_0 to double 10
  let answer = waitFor proxy.ask("worker_0", "multiply", %10)
  assert answer == %30

when isMainModule:
  main()
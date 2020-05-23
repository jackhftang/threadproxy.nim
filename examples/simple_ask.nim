import threadproxy, asyncdispatch

proc workerMain(proxy: ThreadProxy) {.thread.} =
  # register action handler
  proxy.onData "double":
    let x = data.getInt()
    return %(2*x)

  # start processing channel
  waitFor proxy.poll()

proc main() =
  let proxy = newMainThreadProxy("master")
  asyncCheck proxy.poll()

  # create worker thread
  proxy.createThread("worker_0", workerMain)

  # ask worker_0 to double 10
  let answer = waitFor proxy.ask("worker_0", "double", %10)
  assert answer == %20

when isMainModule:
  main()
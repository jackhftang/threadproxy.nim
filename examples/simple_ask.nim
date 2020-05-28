import threadproxy

proc workerMain(proxy: ThreadProxy) {.thread.} =
  # register action handler
  proxy.onData "sum":
    var x = 0
    for n in data:
      x += n.getInt()
    return %x

  # start processing channel
  waitFor proxy.poll()

proc main() =
  let proxy = newMainThreadProxy("master")
  asyncCheck proxy.poll()

  # create worker thread
  proxy.createThread("worker_0", workerMain)

  # ask worker_0 to double 10
  let answer = waitFor proxy.ask("worker_0", "sum", %[2,3,5,7])
  assert answer == %17

when isMainModule:
  main()
import os

import gdb


state = {"before": None, "expected": None, "intervals": 0, "exit_code": None, "shutdown": False}


def exited(event):
    state["exit_code"] = getattr(event, "exit_code", None)


gdb.events.exited.connect(exited)

class Shutdown(gdb.Breakpoint):
    def stop(self):
        state["shutdown"] = True
        return True


def counter(index):
    address = int(gdb.parse_and_eval(
        "&LxrGcHeap::s_heap->m_engine.m_metrics[%d]" % index))
    data = gdb.selected_inferior().read_memory(address, 8).tobytes()
    return int.from_bytes(data, "little")


class Marker(gdb.Breakpoint):
    def stop(self):
        metric = int(gdb.parse_and_eval("$edi")) & 0xFFFFFFFF
        phase = metric & 0xF0000000
        if phase not in (0x80000000, 0x90000000):
            return False
        expected = metric & 0x0FFFFFFF
        current = (counter(2), counter(13))
        if phase == 0x80000000:
            if state["before"] is not None:
                raise RuntimeError("Nested legacy diagnostic interval.")
            state["before"] = current
            state["expected"] = expected
            return False
        if state["before"] is None or expected != state["expected"]:
            raise RuntimeError("Unmatched legacy diagnostic interval.")
        logged = current[0] - state["before"][0]
        old_targets = current[1] - state["before"][1]
        if logged != expected or old_targets != expected:
            raise RuntimeError("Legacy diagnostic logged=%d old=%d expected=%d" %
                               (logged, old_targets, expected))
        state["before"] = None
        state["intervals"] += 1
        print("PASS legacy native counters interval=%d logged=%d old=%d; no timing" %
              (state["intervals"], logged, old_targets))
        return False


gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("set libthread-db-search-path /nonexistent/lxr-control")
gdb.execute("set breakpoint pending on")
gdb.execute("handle SIGXCPU SIGPWR SIGSEGV SIG34 nostop noprint pass")
Marker("GC_LxrPrototype_GetMetric", internal=True)
Shutdown("coreclr_shutdown_2", internal=True)
try:
    gdb.execute("run")
    if not state["shutdown"]:
        raise RuntimeError("The managed program did not reach host shutdown.")
    pid = gdb.selected_inferior().pid
    gdb.execute("detach")
    _, status = os.waitpid(pid, 0)
    state["exit_code"] = os.waitstatus_to_exitcode(status)
    if state["exit_code"] != 0 or state["before"] is not None or state["intervals"] != 34:
        raise RuntimeError("Expected 34 complete legacy native-counter intervals.")
    print("PASS all 34 legacy first-write/repeated native-counter controls; no bulk callback-count claim")
finally:
    if gdb.selected_inferior().pid != 0:
        gdb.execute("kill")

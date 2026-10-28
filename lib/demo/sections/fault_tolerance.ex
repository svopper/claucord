defmodule Demo.Sections.FaultTolerance do
  @moduledoc """
  "Let it crash": processes are isolated, failures are contained, and
  supervisors restart broken parts of the system in a known-good state.
  """
  import Demo.Fmt

  def run do
    header(2, "Fault tolerance: isolation & supervisors")

    supervisor_restart()
    isolated_tasks()
    links_and_trapping()
  end

  defp supervisor_restart do
    step("A one_for_one supervisor with two children: KV and Clock")
    {:ok, sup} = Supervisor.start_link([Demo.KV, Demo.Clock], strategy: :one_for_one)

    kv_before = Process.whereis(Demo.KV)
    clock_before = Process.whereis(Demo.Clock)
    Demo.KV.put(:greeting, "hello")
    info("KV    #{hl(inspect(kv_before))} holds greeting = #{inspect(Demo.KV.get(:greeting))}")
    Process.sleep(200)
    info("Clock #{hl(inspect(clock_before))} has ticked #{Demo.Clock.ticks()} times")

    step("Crashing KV with an unhandled exception…")
    ref = Process.monitor(kv_before)
    Demo.KV.crash!()

    receive do
      {:DOWN, ^ref, :process, _, {%RuntimeError{message: msg}, _}} -> bad("KV died: #{msg}")
    end

    kv_after = wait_for(Demo.KV, kv_before)

    ok(
      "supervisor restarted KV as #{hl(inspect(kv_after))} with fresh state (greeting = #{inspect(Demo.KV.get(:greeting))})"
    )

    ok(
      "Clock untouched: still #{hl(inspect(Process.whereis(Demo.Clock)))}, #{Demo.Clock.ticks()} ticks and counting"
    )

    note("callers never handled the error — the crash was contained to one process")

    Supervisor.stop(sup)
  end

  defp isolated_tasks do
    step("Running 6 jobs concurrently; job #4 raises")

    results =
      1..6
      |> Enum.map(fn i ->
        Task.Supervisor.async_nolink(Demo.TaskSup, fn ->
          Process.sleep(50 * i)
          if i == 4, do: raise(ArgumentError, "bad input for job #{i}")
          {i, i * 100}
        end)
      end)
      |> Task.yield_many(2_000)

    for {_task, res} <- results do
      case res do
        {:ok, {i, v}} -> ok("job #{i} → #{v}")
        {:exit, {%ArgumentError{message: m}, _}} -> bad("#{m} (only this job failed)")
      end
    end
  end

  defp links_and_trapping do
    step("Links propagate failure; trapping exits turns it into a message")
    Process.flag(:trap_exit, true)
    pid = spawn_link(fn -> exit(:disk_on_fire) end)

    receive do
      {:EXIT, ^pid, reason} ->
        ok("linked process exited with #{hl(inspect(reason))} — we got a message, not a crash")
    end

    Process.flag(:trap_exit, false)
    note("this is exactly the mechanism supervisors are built on")
  end

  defp wait_for(name, old_pid) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(5)
        wait_for(name, old_pid)
    end
  end
end

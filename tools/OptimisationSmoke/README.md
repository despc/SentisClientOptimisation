# OptimisationSmoke

Test-only Legacy client plugin for the optimisation settings lifecycle. Do not include it in the user installer or enable it in a normal Pulsar profile.

1. Build `OptimisationSmoke.csproj` with the .NET SDK; it targets .NET Framework 4.8 and references the installed game through `SeBin`.
2. Prepare a separate test directory with a copy of Pulsar, a separate game data directory, and a copy of the game's `Content/CustomWorlds/Empty World` template in `<test-root>/world`.
3. Enable only `SentisClientOptimisation.dll` and `OptimisationSmoke.dll` in the copied Pulsar Legacy profile.
4. Set `SENTIS_OPT_SMOKE_ROOT` to the test root for the child process only. Launch the copied `Legacy.exe` without `-useHome`, with `-appdata <test-root>/game` and the installed game's `-bin64` path.
5. The harness verifies that the active game data path is inside the test root. It then exercises Russian and English menu text, control creation, Cancel, Apply, Reset, persistence, live render and particle limits, restoration around native graphics settings, and world reload.

The harness writes `report.txt`, screenshots and `done.txt` (`PASS` or `FAIL`) inside the test root. A successful run exits the test client. A failed run leaves the client open for inspection. The harness changes settings and loads/unloads a world: use only the isolated profile and copied test world.

Native screens are queued for insertion; the harness inspects both active and pending screens after invoking a button. Offline binding and structural tests do not replace this client run.

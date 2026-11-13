using System;
using HarmonyLib;
using VRage.Plugins;
using VRage.Utils;

namespace SentisClientOptimisation
{
    /// <summary>
    /// A Pulsar plugin of fixes of the game client's freezes. Each fix patches on its own: one the game changed under
    /// it is left out, with a line in the game's log, and the others work.
    /// </summary>
    public class Plugin : IPlugin
    {
        public const string Id = "SentisClientOptimisation";

        private Harmony _harmony;

        public void Init(object gameInstance)
        {
            Log("Loading v" + typeof(Plugin).Assembly.GetName().Version);
            _harmony = new Harmony(Id);
            OptimisationPreferences.Load();

            Log($"GC: {(System.Runtime.GCSettings.IsServerGC ? "server" : "workstation")}, {System.Runtime.GCSettings.LatencyMode}, " +
                $"gen0 budget {Environment.GetEnvironmentVariable("COMPlus_GCgen0MaxBudget") ?? "default"}");
            Patch("VoxelCacheSave", VoxelCacheSave.Patch);
            Patch("BulkChildDelete", BulkChildDelete.Patch);
            Patch("ConveyorCloseUnsubscribe", ConveyorCloseUnsubscribe.Patch);
            Patch("PoolCap", PoolCap.Patch);
            Patch("GridLoadAsync", GridLoadAsync.Patch);
            Patch("ProjectionPreclone", ProjectionPreclone.Patch);
            Patch("ThrustConveyorScc", ThrustConveyorScc.Patch);
            Patch("VoxelLoadAsync", VoxelLoadAsync.Patch);
            Patch("PlanetDetailNoGc", PlanetDetailNoGc.Patch);
            Patch("GroupPowerOnce", GroupPowerOnce.Patch);
            Patch("LinePowerOnce", LinePowerOnce.Patch);
            Patch("PowerReadOnce", PowerReadOnce.Patch);
            Patch("OptimisationMenu", OptimisationMenu.Patch);
            Patch("OptimisationRuntime", OptimisationRuntime.Initialize);

            Log("Initialization complete");
            MyLog.Default?.Flush();
        }

        private void Patch(string name, Action<Harmony> patch)
        {
            try
            {
                patch(_harmony);
                Log(name + " on");
            }
            catch (Exception e)
            {
                Log(name + " left out: " + e);
            }
        }

        public void Update()
        {
            ConveyorCloseUnsubscribe.Flush();
            OptimisationMenu.Refresh();
            OptimisationRuntime.Update();

        }



        public void Dispose()
        {
            try { OptimisationRuntime.Dispose(); }
            catch (Exception e) { Log("Optimisation cleanup: " + e); }

            try { _harmony?.UnpatchAll(Id); }
            catch (Exception) { }
        }

        public void OpenConfigDialog() => OptimisationMenu.Open();

        internal static void Log(string text) => MyLog.Default?.WriteLine(Id + ": " + text);
    }
}

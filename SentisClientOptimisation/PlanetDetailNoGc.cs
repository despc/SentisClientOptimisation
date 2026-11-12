using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using System.Threading;
using HarmonyLib;

namespace SentisClientOptimisation
{
    /// <summary>
    /// A planet's voxel storage made on the client no longer stops the game for a full garbage collection.
    ///
    /// Every time a planet's storage is made (a planet streamed with its data, its storage given anew), its shape
    /// provider reads the planet's detail texture (<c>MyPlanetTextureMapProvider.GetDetailMap</c>) and then forces a
    /// full blocking collection (<c>MyVRage.Platform.System.CollectGC(GC.MaxGeneration, GCCollectionMode.Default)</c>): 1.6 s of one frame in a
    /// trace of a player's client, the texture itself 0.05 s of it (11.11.2026). The collection only frees the reading's
    /// buffers sooner; the runtime frees them when it needs to. It is not forced there now. (The game's collections
    /// when a planet's maps are first read and cached, once a planet type, are left as they are.)
    /// </summary>
    internal static class PlanetDetailNoGc
    {
        public static long Skipped;

        public static void Patch(Harmony harmony)
        {
            var type = AccessTools.TypeByName("Sandbox.Engine.Voxels.Planet.MyPlanetTextureMapProvider") ?? throw new TypeLoadException("MyPlanetTextureMapProvider");
            var detail = AccessTools.Method(type, "GetDetailMap", new[] { typeof(string) }) ?? throw new MissingMethodException(type.Name, "GetDetailMap");
            harmony.Patch(detail, transpiler: new HarmonyMethod(typeof(PlanetDetailNoGc), nameof(Transpiler)));
        }

        private static IEnumerable<CodeInstruction> Transpiler(IEnumerable<CodeInstruction> instructions)
        {
            var code = instructions.ToList();
            var replaced = 0;
            foreach (var instruction in code)
            {
                if ((instruction.opcode == OpCodes.Callvirt || instruction.opcode == OpCodes.Call) && instruction.operand is MethodInfo method &&
                    method.Name == "CollectGC" && method.GetParameters().Length == 2 && method.GetParameters()[0].ParameterType == typeof(int) &&
                    method.GetParameters()[1].ParameterType == typeof(GCCollectionMode) && method.ReturnType == typeof(void))
                {
                    // [system, generation, mode] -> NotCollected(system, generation, mode)
                    instruction.opcode = OpCodes.Call;
                    instruction.operand = AccessTools.Method(typeof(PlanetDetailNoGc), nameof(NotCollected));
                    replaced++;
                }
            }
            if (replaced != 1) throw new InvalidOperationException($"MyPlanetTextureMapProvider.GetDetailMap is not what this fix knows: {replaced} collections");
            return code;
        }

        public static void NotCollected(object system, int generation, GCCollectionMode mode) => Interlocked.Increment(ref Skipped);
    }
}

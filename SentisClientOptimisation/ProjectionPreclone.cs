using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.CompilerServices;
using System.Threading;
using HarmonyLib;
using Sandbox;
using Sandbox.Game.Entities.Blocks;
using VRage.Game;
using VRage.ObjectBuilders;

namespace SentisClientOptimisation
{
    /// <summary>
    /// A projector streamed to the client no longer copies its blueprint on the game thread.
    ///
    /// A projector keeps its blueprint's grids as it was given them (<c>m_savedProjections</c>), and on its first
    /// update (<c>MyProjectorBase.UpdateOnceBeforeFrame</c>) works on a copy of each (<c>Clone</c>: the whole blueprint
    /// written and read again) - 1.4 s of the game thread in a minute's trace of a player's client, 1.2 s of one frame
    /// (11.11.2026). Now, when the projector is made off the game thread (a streamed grid is made on the entity creation
    /// thread), the copies are made there, at its <c>Init</c>; the first update takes them. The copy is of the same
    /// blueprint, untouched in between (the game keeps it as it is, to save it), so it is what the game would make.
    /// A projector made on the game thread copies as the game does.
    /// </summary>
    internal static class ProjectionPreclone
    {
        public static long Made, Taken;

        private static AccessTools.FieldRef<MyProjectorBase, List<MyObjectBuilder_CubeGrid>> _saved;

        private static readonly ConditionalWeakTable<MyObjectBuilder_Base, MyObjectBuilder_Base> Copies = new ConditionalWeakTable<MyObjectBuilder_Base, MyObjectBuilder_Base>();

        public static void Patch(Harmony harmony)
        {
            _saved = AccessTools.FieldRefAccess<MyProjectorBase, List<MyObjectBuilder_CubeGrid>>("m_savedProjections");
            var init = AccessTools.Method(typeof(MyProjectorBase), nameof(MyProjectorBase.Init), new[] { typeof(MyObjectBuilder_CubeBlock), typeof(Sandbox.Game.Entities.MyCubeGrid) })
                       ?? throw new MissingMethodException("MyProjectorBase", "Init");
            var update = AccessTools.Method(typeof(MyProjectorBase), nameof(MyProjectorBase.UpdateOnceBeforeFrame), Type.EmptyTypes)
                         ?? throw new MissingMethodException("MyProjectorBase", "UpdateOnceBeforeFrame");
            harmony.Patch(update, transpiler: new HarmonyMethod(typeof(ProjectionPreclone), nameof(Transpiler)));
            harmony.Patch(init, postfix: new HarmonyMethod(typeof(ProjectionPreclone), nameof(InitPostfix)));
        }

        private static IEnumerable<CodeInstruction> Transpiler(IEnumerable<CodeInstruction> instructions)
        {
            var clone = AccessTools.Method(typeof(MyObjectBuilder_Base), nameof(MyObjectBuilder_Base.Clone), Type.EmptyTypes);
            var code = instructions.ToList();
            var replaced = 0;
            foreach (var instruction in code)
            {
                if ((instruction.opcode == OpCodes.Callvirt || instruction.opcode == OpCodes.Call) && instruction.operand is MethodInfo method && method == clone)
                {
                    instruction.opcode = OpCodes.Call;
                    instruction.operand = AccessTools.Method(typeof(ProjectionPreclone), nameof(Take));
                    replaced++;
                }
            }
            if (replaced != 1) throw new InvalidOperationException($"MyProjectorBase.UpdateOnceBeforeFrame is not what this fix knows: {replaced} clones");
            return code;
        }

        /// <summary>The copies of the blueprint made where the projector is made, off the game thread.</summary>
        private static void InitPostfix(MyProjectorBase __instance)
        {
            try
            {
                var saved = _saved(__instance);
                if (saved == null || saved.Count == 0 || OnGameThread()) return;
                foreach (var grid in saved) Keep(grid, grid.Clone());
            }
            catch (Exception e)
            {
                Plugin.Log("copying a projector's blueprint: " + e);
            }
        }

        private static bool OnGameThread()
        {
            var game = MySandboxGame.Static?.UpdateThread;
            return game == null || game == Thread.CurrentThread;
        }

        internal static void Keep(MyObjectBuilder_Base original, MyObjectBuilder_Base copy)
        {
            Copies.Remove(original);
            Copies.Add(original, copy);
            Interlocked.Increment(ref Made);
        }

        /// <summary>The copy made before, taken once; or a copy made now, as the game makes it.</summary>
        public static MyObjectBuilder_Base Take(MyObjectBuilder_Base original)
        {
            if (original != null && Copies.TryGetValue(original, out var copy) && Copies.Remove(original))
            {
                Interlocked.Increment(ref Taken);
                return copy;
            }
            return original.Clone();
        }
    }
}

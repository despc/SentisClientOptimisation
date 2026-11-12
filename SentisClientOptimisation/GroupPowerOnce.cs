using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using HarmonyLib;
using Sandbox.Game.Entities;
using Sandbox.Game.Entities.Cube;
using Sandbox.Game.EntityComponents;

namespace SentisClientOptimisation
{
    /// <summary>
    /// Grids joined or parted (a connector locked, a rotor attached, a link broken) recompute their power once, not
    /// once a grid.
    ///
    /// A grid that comes into a logical group, or leaves one (<c>MyCubeGridSystems.OnAddedToGroup</c> /
    /// <c>OnRemovedFromGroup</c>), gives its blocks to the group's resource distributor and at once recomputes the whole
    /// distribution (<c>MyResourceDistributorComponent.UpdateBeforeSimulation</c>); when two groups merge or one splits
    /// every grid moved does it, each over the whole group - and the game recomputes all of it again the next frame
    /// anyway (a scheduled <c>SetNeedRecomputeAll</c>). 1.5 s of a trace of a player's client (11.11.2026, 22:56).
    ///
    /// Now, while a link is made or broken (<c>MyCubeGridGroups.CreateLink</c> / <c>BreakLink</c>), the grids' recomputes
    /// are kept and made once a distributor when it is done: the last of the game's recomputes, over the same blocks,
    /// gives the same distribution. A grid joining or leaving by itself (made, removed) recomputes as the game does.
    /// </summary>
    internal static class GroupPowerOnce
    {
        public static long Kept, Made;

        [ThreadStatic] private static int _depth;
        [ThreadStatic] private static List<MyResourceDistributorComponent> _pending;

        public static void Patch(Harmony harmony)
        {
            var update = AccessTools.Method(typeof(MyResourceDistributorComponent), nameof(MyResourceDistributorComponent.UpdateBeforeSimulation), Type.EmptyTypes)
                         ?? throw new MissingMethodException("MyResourceDistributorComponent", "UpdateBeforeSimulation");
            var added = AccessTools.Method(typeof(MyCubeGridSystems), nameof(MyCubeGridSystems.OnAddedToGroup), new[] { typeof(MyGridLogicalGroupData) }) ?? throw new MissingMethodException("MyCubeGridSystems", "OnAddedToGroup");
            var removed = AccessTools.Method(typeof(MyCubeGridSystems), nameof(MyCubeGridSystems.OnRemovedFromGroup), new[] { typeof(MyGridLogicalGroupData) }) ?? throw new MissingMethodException("MyCubeGridSystems", "OnRemovedFromGroup");
            var link = AccessTools.Method(typeof(MyCubeGridGroups), nameof(MyCubeGridGroups.CreateLink)) ?? throw new MissingMethodException("MyCubeGridGroups", "CreateLink");
            var unlink = AccessTools.Method(typeof(MyCubeGridGroups), nameof(MyCubeGridGroups.BreakLink)) ?? throw new MissingMethodException("MyCubeGridGroups", "BreakLink");
            _update = update;
            var self = typeof(GroupPowerOnce);
            harmony.Patch(added, transpiler: new HarmonyMethod(self, nameof(Transpiler)));
            harmony.Patch(removed, transpiler: new HarmonyMethod(self, nameof(Transpiler)));
            harmony.Patch(link, prefix: new HarmonyMethod(self, nameof(Begin)), finalizer: new HarmonyMethod(self, nameof(End)));
            harmony.Patch(unlink, prefix: new HarmonyMethod(self, nameof(Begin)), finalizer: new HarmonyMethod(self, nameof(End)));
        }

        private static MethodInfo _update;

        /// <summary>The recompute right after a grid's blocks are given or taken (not the scheduled one, a closure of its own).</summary>
        private static IEnumerable<CodeInstruction> Transpiler(IEnumerable<CodeInstruction> instructions)
        {
            var code = instructions.ToList();
            var replaced = 0;
            foreach (var instruction in code)
            {
                if ((instruction.opcode == OpCodes.Callvirt || instruction.opcode == OpCodes.Call) && instruction.operand is MethodInfo method && method == _update)
                {
                    instruction.opcode = OpCodes.Call;
                    instruction.operand = AccessTools.Method(typeof(GroupPowerOnce), nameof(Recompute));
                    replaced++;
                }
            }
            if (replaced != 1) throw new InvalidOperationException($"a grid's joining or leaving of a group is not what this fix knows: {replaced} recomputes");
            return code;
        }

        public static void Recompute(MyResourceDistributorComponent distributor)
        {
            if (_depth == 0 || distributor == null)
            {
                distributor?.UpdateBeforeSimulation();
                return;
            }
            var pending = _pending ?? (_pending = new List<MyResourceDistributorComponent>());
            if (!pending.Contains(distributor)) pending.Add(distributor);
            Kept++;
        }

        private static void Begin() => _depth++;

        private static Exception End(Exception __exception)
        {
            if (--_depth > 0) return __exception;
            _depth = 0;
            var pending = _pending;
            if (pending == null || pending.Count == 0) return __exception;
            var distributors = pending.ToArray();
            pending.Clear();
            foreach (var distributor in distributors)
            {
                try
                {
                    distributor.UpdateBeforeSimulation();
                    Made++;
                }
                catch (Exception e)
                {
                    Plugin.Log("recomputing the power of joined grids: " + e);
                }
            }
            return __exception;
        }
    }
}

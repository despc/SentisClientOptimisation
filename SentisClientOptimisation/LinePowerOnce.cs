using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.CompilerServices;
using HarmonyLib;
using Sandbox;
using Sandbox.Game.EntityComponents;
using Sandbox.Game.GameSystems.Conveyors;
using VRage;
using VRage.Game;
using VRage.Game.ModAPI;

namespace SentisClientOptimisation
{
    /// <summary>
    /// A grid's conveyor lines ask for its power once a frame, not once a line with the whole distribution recomputed.
    ///
    /// When a grid's conveyors change or its power does, every conveyor line is told (<c>MyConveyorLine.UpdateIsFunctional</c>)
    /// and asks the grid's distributor whether there is electricity (<c>UpdateIsWorking</c> →
    /// <c>ResourceStateByType</c>); a line that changes marks the conveyors for a recompute, the distributor is dirty, and
    /// the next line's question recomputes the whole distribution - a recompute a line. 4.7 s of a trace of a player's
    /// client, 2.1 s of one frame (11.11.2026, 23:29).
    ///
    /// Now, on the game thread, the lines of a distributor take the state the first of them got that frame. The
    /// distributor stays marked for its recompute: the next question of anyone else (the game's own updates) makes it;
    /// should the electricity change by it, the conveyor system's power event tells the lines again, as in the game.
    /// </summary>
    internal static class LinePowerOnce
    {
        public static long Asked, Kept;

        private static MethodInfo _state;

        public static void Patch(Harmony harmony)
        {
            _state = AccessTools.Method(typeof(MyResourceDistributorComponent), nameof(MyResourceDistributorComponent.ResourceStateByType),
                         new[] { typeof(MyDefinitionId), typeof(bool), typeof(Sandbox.Game.Entities.MyCubeGrid) })
                     ?? throw new MissingMethodException("MyResourceDistributorComponent", "ResourceStateByType");
            var working = AccessTools.Method(typeof(MyConveyorLine), nameof(MyConveyorLine.UpdateIsWorking)) ?? throw new MissingMethodException("MyConveyorLine", "UpdateIsWorking");
            harmony.Patch(working, transpiler: new HarmonyMethod(typeof(LinePowerOnce), nameof(Transpiler)));
        }

        private static IEnumerable<CodeInstruction> Transpiler(IEnumerable<CodeInstruction> instructions)
        {
            var code = instructions.ToList();
            var replaced = 0;
            foreach (var instruction in code)
            {
                if ((instruction.opcode == OpCodes.Callvirt || instruction.opcode == OpCodes.Call) && instruction.operand is MethodInfo method && method == _state)
                {
                    instruction.opcode = OpCodes.Call;
                    instruction.operand = AccessTools.Method(typeof(LinePowerOnce), nameof(State));
                    replaced++;
                }
            }
            if (replaced != 1) throw new InvalidOperationException($"MyConveyorLine.UpdateIsWorking is not what this fix knows: {replaced} questions");
            return code;
        }

        /// <summary>The game's <c>ResourceStateByType</c> of a line: once a frame a distributor, on the game thread.</summary>
        public static MyResourceStateEnum State(MyResourceDistributorComponent distributor, MyDefinitionId typeId, bool withRecompute, Sandbox.Game.Entities.MyCubeGrid grid)
        {
            var game = MySandboxGame.Static;
            if (game == null || grid != null || !withRecompute || typeId != MyResourceDistributorComponent.ElectricityId ||
                game.UpdateThread != System.Threading.Thread.CurrentThread)
                return distributor.ResourceStateByType(typeId, withRecompute, grid);
            var frame = game.SimulationFrameCounter;
            if (PowerAnswers.Has(distributor, frame, out var kept))
            {
                Kept++;
                return kept;
            }
            Asked++;
            var state = distributor.ResourceStateByType(typeId, withRecompute, grid);
            PowerAnswers.Keep(distributor, frame, state);
            return state;
        }
    }
}

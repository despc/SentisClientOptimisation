using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using HarmonyLib;
using Sandbox;
using Sandbox.Game.EntityComponents;
using SpaceEngineers.Game.Entities.Blocks;
using VRage;

namespace SentisClientOptimisation
{
    /// <summary>
    /// The sound of a grid and its upgrade modules read its power once a frame, not once a look.
    ///
    /// The sound of a grid (<c>MyShipSoundComponent.UpdateState</c>, every frame) and every upgrade module of it
    /// (<c>MyUpgradeModule.UpdateBeforeSimulation100</c>, which looks three times a tick) read its whole resource
    /// state (the game's <c>MyResourceDistributorComponent.ResourceState</c> getter - a <c>ResourceStateByType</c>
    /// of the first registered type, the electricity, to recompute, without a grid); with the distributor dirty
    /// every look recomputes the whole distribution: 1.6 s and 1.9 s of a trace of a player's client, in frames of
    /// up to 1.3 s (12.11.2026, 12:27).
    ///
    /// Now, on the game thread, these readers take the answer the first question of the frame got - the same answer
    /// the conveyor lines take (<c>LinePowerOnce</c>; the questions are the same). The distributor keeps its own
    /// schedule: the game's own questions recompute as they did; a state that changed after the first look is seen
    /// by these readers the next frame - the sound and the module's lamps and idle sound do not drive the
    /// simulation between the looks, and both look again soon: the sound every frame, a module in 100 ms.
    /// </summary>
    internal static class PowerReadOnce
    {
        public static long Asked, Kept;

        private static MethodInfo _look;
        private static int _expected;

        public static void Patch(Harmony harmony)
        {
            _look = AccessTools.Method(typeof(MyResourceDistributorComponent), "get_ResourceState")
                    ?? throw new MissingMethodException("MyResourceDistributorComponent", "get_ResourceState");
            var self = typeof(PowerReadOnce);
            var left = new List<string>();
            Try(harmony, left, typeof(MyShipSoundComponent), "UpdateState", 1, self, nameof(Transpiler));
            Try(harmony, left, typeof(MyUpgradeModule), "UpdateBeforeSimulation100", 3, self, nameof(Transpiler));
            if (left.Count == 2) throw new InvalidOperationException("no reader is what this fix knows: " + string.Join("; ", left));
            if (left.Count > 0) Plugin.Log("only some readers patched: " + string.Join("; ", left));
        }

        private static void Try(Harmony harmony, List<string> left, Type type, string method, int expected, Type self, string transpiler)
        {
            try
            {
                _expected = expected;
                harmony.Patch(AccessTools.Method(type, method), transpiler: new HarmonyMethod(self, transpiler));
            }
            catch (Exception e)
            {
                left.Add(type.Name + "." + method + ": " + e.Message);
            }
        }

        /// <summary>Every look of the reader at the grid's resource state, replaced with <see cref="State"/>.</summary>
        private static IEnumerable<CodeInstruction> Transpiler(IEnumerable<CodeInstruction> instructions)
        {
            var code = instructions.ToList();
            var replaced = 0;
            foreach (var instruction in code)
            {
                if ((instruction.opcode == OpCodes.Callvirt || instruction.opcode == OpCodes.Call) && instruction.operand is MethodInfo method && method == _look)
                {
                    instruction.opcode = OpCodes.Call;
                    instruction.operand = AccessTools.Method(typeof(PowerReadOnce), nameof(State));
                    replaced++;
                }
            }
            if (replaced != _expected) throw new InvalidOperationException($"a reader of the grid's power is not what this fix knows: {replaced} looks, expected {_expected}");
            return code;
        }

        /// <summary>The game's <c>ResourceState</c> of a reader: once a frame a distributor, on the game thread.</summary>
        public static MyResourceStateEnum State(MyResourceDistributorComponent distributor)
        {
            var game = MySandboxGame.Static;
            // a distributor missing is the game's own NullReferenceException, as the virtual call on it
            if (distributor == null || game == null || game.UpdateThread != System.Threading.Thread.CurrentThread)
                return distributor.ResourceState;
            var frame = game.SimulationFrameCounter;
            if (PowerAnswers.Has(distributor, frame, out var kept))
            {
                Kept++;
                return kept;
            }
            Asked++;
            var state = distributor.ResourceState;
            PowerAnswers.Keep(distributor, frame, state);
            return state;
        }
    }
}

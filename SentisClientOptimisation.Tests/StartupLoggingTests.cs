using System.Linq;
using System.Reflection.Emit;
using HarmonyLib;
using Xunit;

namespace SentisClientOptimisation.Tests
{
    public sealed class StartupLoggingTests
    {
        [Fact]
        public void Initialization_announces_version_and_completion_and_flushes_game_log()
        {
            // Structural check only: actual in-game initialization is a separate acceptance gate.
            var instructions = PatchProcessor.GetOriginalInstructions(AccessTools.Method(typeof(Plugin), nameof(Plugin.Init)));
            Assert.Contains(instructions, i => i.opcode == OpCodes.Ldstr && Equals(i.operand, "Loading v"));
            Assert.Contains(instructions, i => i.opcode == OpCodes.Ldstr && Equals(i.operand, "Initialization complete"));
            Assert.Contains(instructions, i => i.operand is System.Reflection.MethodInfo method &&
                method.DeclaringType == typeof(VRage.Utils.MyLog) && method.Name == "Flush");
        }
    }
}

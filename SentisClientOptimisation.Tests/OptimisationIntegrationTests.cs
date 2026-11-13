using System;
using System.Linq;
using System.Reflection;
using HarmonyLib;
using Xunit;

namespace SentisClientOptimisation.Tests
{
    public sealed class OptimisationIntegrationTests
    {
        private static bool Calls(string entry, string type, string method)
        {
            return PatchProcessor.GetOriginalInstructions(AccessTools.Method(typeof(Plugin), entry))
                .Any(i => i.operand is MethodBase m && m.DeclaringType?.Name == type && m.Name == method);
        }

        [Fact]
        public void Plugin_loads_preferences_before_registering_optional_features()
        {
            Assert.True(Calls(nameof(Plugin.Init), "OptimisationPreferences", "Load"));
            // Registration uses the same independently guarded Patch helper as existing fixes.
            var il = PatchProcessor.GetOriginalInstructions(AccessTools.Method(typeof(Plugin), nameof(Plugin.Init)));
            Assert.Contains(il, i => i.operand is MethodBase m && m.DeclaringType?.Name == "OptimisationMenu" && m.Name == "Patch");
            Assert.Contains(il, i => i.operand is MethodBase m && m.DeclaringType?.Name == "OptimisationRuntime" && m.Name == "Initialize");
        }

        [Fact]
        public void Plugin_updates_and_restores_optional_features()
        {
            Assert.True(Calls(nameof(Plugin.Update), "OptimisationRuntime", "Update"));
            Assert.True(Calls(nameof(Plugin.Dispose), "OptimisationRuntime", "Dispose"));
        }

        [Fact]
        public void Pulsar_configuration_entry_opens_same_native_screen()
        {
            var method = typeof(Plugin).GetMethod("OpenConfigDialog", BindingFlags.Public | BindingFlags.Instance);
            Assert.NotNull(method);
            Assert.True(Calls(method.Name, "OptimisationMenu", "Open"));
        }
    }
}

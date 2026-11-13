using System;
using System.Linq;
using System.Reflection;
using HarmonyLib;
using Sandbox.Graphics.GUI;
using Xunit;

namespace SentisClientOptimisation.Tests
{
    public sealed class OptimisationMenuTests
    {
        [Fact]
        public void Native_options_hook_targets_recreate_and_supports_language_refresh()
        {
            // Structural gate only: native GUI patch execution is exercised by OptimisationSmoke in the real client.
            // Patching this GUI method in isolation can initialize renderer textures before a platform exists.
            var type = typeof(Plugin).Assembly.GetType("SentisClientOptimisation.OptimisationMenu");
            Assert.NotNull(type);
            var options = Type.GetType("SpaceEngineers.Game.GUI.MyGuiScreenOptionsSpace, SpaceEngineers.Game", true);
            Assert.NotNull(AccessTools.DeclaredMethod(options, "RecreateControls", new[] { typeof(bool) }));
            var instructions = PatchProcessor.GetOriginalInstructions(type.GetMethod("Patch", BindingFlags.Static | BindingFlags.NonPublic));
            Assert.Contains(instructions, i => Equals(i.operand, "RecreateControls"));
            Assert.Contains(instructions, i => i.operand is MethodBase method && method.DeclaringType == typeof(Harmony) && method.Name == "Patch");
            Assert.NotNull(type.GetMethod("Refresh", BindingFlags.Static | BindingFlags.NonPublic));
        }

        [Fact]
        public void Screen_exposes_every_supported_setting_without_omissions()
        {
            var type = typeof(Plugin).Assembly.GetType("SentisClientOptimisation.OptimisationScreen");
            Assert.NotNull(type);
            Assert.True(typeof(MyGuiScreenBase).IsAssignableFrom(type));
            var keys = (string[])type.GetField("SettingKeys", BindingFlags.Static | BindingFlags.NonPublic).GetValue(null);
            Assert.Equal(typeof(OptimisationSettings).GetProperties().Select(p => p.Name).OrderBy(x => x), keys.OrderBy(x => x));
            Assert.Equal(keys.Length, keys.Distinct().Count());
        }
    }
}

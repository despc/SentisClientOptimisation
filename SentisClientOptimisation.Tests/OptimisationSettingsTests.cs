using System;
using System.Linq;
using System.Reflection;
using Xunit;

namespace SentisClientOptimisation.Tests
{
    public sealed class OptimisationSettingsTests
    {
        [Fact]
        public void Invalid_numeric_preferences_are_clamped()
        {
            var settings = new OptimisationSettings { TargetFps = -1, MaxParticles = int.MaxValue, ParticleDistance = 0, LodPercent = 999, DistanceFade = -40 };
            var normalize = typeof(OptimisationSettings).GetMethod("Normalize");
            Assert.NotNull(normalize);
            normalize.Invoke(settings, null);
            Assert.Equal(20, settings.TargetFps);
            Assert.Equal(1000, settings.MaxParticles);
            Assert.Equal(40, settings.ParticleDistance);
            Assert.Equal(100, settings.LodPercent);
            Assert.Equal(120, settings.DistanceFade);
        }

        [Fact]
        public void Preferences_round_trip_and_corrupt_files_are_preserved()
        {
            var type = typeof(Plugin).Assembly.GetType("SentisClientOptimisation.OptimisationPreferences");
            Assert.NotNull(type);
            var dir = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "hermes", "cache", "scratch", "sco-prefs-" + Guid.NewGuid().ToString("N"));
            var path = System.IO.Path.Combine(dir, "settings.xml");
            try
            {
                var flags = BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;
                var save = type.GetMethod("SaveTo", flags);
                var load = type.GetMethod("LoadFrom", flags);
                var expected = new OptimisationSettings { DisableFog = true, MaxParticles = 432 };
                Assert.True((bool)save.Invoke(null, new object[] { path, expected }));
                var actual = (OptimisationSettings)load.Invoke(null, new object[] { path });
                Assert.True(actual.DisableFog);
                Assert.Equal(432, actual.MaxParticles);
                System.IO.File.WriteAllText(path, "<broken");
                var fallback = (OptimisationSettings)load.Invoke(null, new object[] { path });
                Assert.False(fallback.DisableFog);
                Assert.Equal("<broken", System.IO.File.ReadAllText(path));
            }
            finally { if (System.IO.Directory.Exists(dir)) System.IO.Directory.Delete(dir, true); }
        }

        [Fact]
        public void Graphics_changes_are_opt_in_and_clones_are_independent()
        {
            var type = typeof(Plugin).Assembly.GetType("SentisClientOptimisation.OptimisationSettings");
            Assert.NotNull(type);
            var settings = Activator.CreateInstance(type);
            foreach (var p in type.GetProperties().Where(p => p.PropertyType == typeof(bool)))
                Assert.False((bool)p.GetValue(settings), p.Name);
            var clone = type.GetMethod("Clone").Invoke(settings, null);
            type.GetProperty("DisableShadows").SetValue(clone, true);
            Assert.False((bool)type.GetProperty("DisableShadows").GetValue(settings));
        }
    }
}

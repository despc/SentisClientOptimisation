using System;
using System.Reflection;
using VRageRender;
using VRageRender.Messages;
using Xunit;

namespace SentisClientOptimisation.Tests
{
    public sealed class OptimisationRuntimeTests
    {
        [Fact]
        public void Adaptive_limits_require_sustained_render_load_and_recover()
        {
            var type = typeof(Plugin).Assembly.GetType("SentisClientOptimisation.AdaptiveLimits");
            Assert.NotNull(type);

            var controller = Activator.CreateInstance(type, true);
            var tick = type.GetMethod("Tick", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
            bool Step(double seconds, float frame, float gpu, float cpu, bool eligible) => (bool)tick.Invoke(controller, new object[] { seconds, frame, gpu, cpu, 60, eligible });
            for (var i = 0; i < 20; i++) Assert.False(Step(0.5, 60f, 2f, 2f, true)); // Simulation load alone must not lower graphics.
            bool active = false;
            for (var i = 0; i < 20; i++) active = Step(0.5, 40f, 35f, 3f, true);
            Assert.True(active);
            for (var i = 0; i < 20; i++) active = Step(0.5, 10f, 8f, 3f, true);
            Assert.False(active);
            Assert.False(Step(0.5, 40f, 35f, 3f, false));
        }

        [Fact]
        public void Particle_limits_keep_unknown_and_parented_distant_cues()
        {
            var type = typeof(Plugin).Assembly.GetType("SentisClientOptimisation.ParticleLimits");
            Assert.NotNull(type);
            var method = type.GetMethod("ShouldSkip", BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public);
            var config = new OptimisationSettings { LimitParticles = true };
            bool Skip(string name, int count, uint parent, double distance) => (bool)method.Invoke(null, new object[] { config, false, name, count, parent, distance });
            Assert.True(Skip("Smoke_DrillDust", 1000, uint.MaxValue, 0));
            Assert.True(Skip("Smoke_DrillDust", 0, uint.MaxValue, 1000000));
            Assert.False(Skip("Smoke_DrillDust", 0, 42, 1000000));
            Assert.False(Skip("Smoke_Missile", 1000, uint.MaxValue, 1000000));
            Assert.False(Skip("UnknownModEffect", 1000, uint.MaxValue, 1000000));
            config.LimitParticles = false;
            Assert.False(Skip("Smoke_DrillDust", 1000, uint.MaxValue, 1000000));
        }

        [Fact]
        public void Native_runtime_hooks_fit_the_installed_game()
        {
            var type = typeof(Plugin).Assembly.GetType("SentisClientOptimisation.OptimisationRuntime");
            Assert.NotNull(type);
            var method = type.GetMethod("Initialize", BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public);
            var h = new HarmonyLib.Harmony("SentisClientOptimisation.runtime-binding-tests");
            try { method.Invoke(null, new object[] { h }); }
            finally { h.UnpatchAll(h.Id); }
        }

        [Fact]
        public void Repeated_overrides_do_not_compound_and_external_changes_become_baseline()
        {
            var lease = new ValueLease<float>();
            Assert.Equal(0.5f, lease.Apply(1f, true, value => value * 0.5f));
            Assert.Equal(0.5f, lease.Apply(0.5f, true, value => value * 0.5f));
            Assert.Equal(1f, lease.Apply(2f, true, value => value * 0.5f));
            Assert.Equal(2f, lease.Apply(1f, false, value => value));
            Assert.Equal(3f, lease.Apply(3f, false, value => value));
        }

        [Fact]
        public void External_change_during_override_is_not_lost_on_disable()
        {
            var tuning = new RenderTuning();
            var settings = default(MyRenderSettings);
            settings.FlaresIntensity = 1f;
            var debug = new MyRenderDebugOverrides();
            tuning.Apply(ref settings, debug, new OptimisationSettings { DisableFlares = true }, false);
            settings.FlaresIntensity = 0.7f;
            settings.User.DRScaling = true;
            tuning.Apply(ref settings, debug, new OptimisationSettings(), false);
            Assert.Equal(0.7f, settings.FlaresIntensity);
            Assert.True(settings.User.DRScaling);
        }

        [Fact]
        public void Default_configuration_does_not_write_renderer_settings()
        {
            var tuning = new RenderTuning();
            var settings = default(MyRenderSettings);
            settings.EnableShadows = true;
            settings.User.DistanceFade = 700;
            var debug = new MyRenderDebugOverrides { Fxaa = false, EnableDRS = true };
            tuning.Apply(ref settings, debug, new OptimisationSettings(), false);
            Assert.False(tuning.RenderChanged);
            Assert.False(tuning.DebugChanged);
            Assert.True(settings.EnableShadows);
            Assert.Equal(700f, settings.User.DistanceFade);
            Assert.False(debug.Fxaa);
            Assert.True(debug.EnableDRS);
        }

        [Fact]
        public void Visual_toggles_restore_their_fields_without_touching_dynamic_resolution()
        {
            var tuning = new RenderTuning();
            var original = default(MyRenderSettings);
            original.User.DRScaling = true;
            original.FlaresIntensity = 2.5f;
            var debug = new MyRenderDebugOverrides { EnableDRS = true, Fog = true, Bloom = true, Tonemapping = true };
            var changed = original;
            tuning.Apply(ref changed, debug, new OptimisationSettings { DisableFog = true, DisableBloom = true, DisableFlares = true, DisableShadows = true }, false);
            Assert.False(debug.Fog);
            Assert.False(debug.Bloom);
            Assert.True(debug.Tonemapping);
            Assert.Equal(0f, changed.FlaresIntensity);
            Assert.True(changed.User.DRScaling);
            Assert.True(debug.EnableDRS);
            tuning.Apply(ref changed, debug, new OptimisationSettings(), false);
            var restored = changed;
            Assert.Equal(original.FlaresIntensity, restored.FlaresIntensity);
            Assert.Equal(original.EnableShadows, restored.EnableShadows);
            Assert.True(debug.Fog);
            Assert.True(debug.Bloom);
            Assert.True(debug.EnableDRS);
            Assert.True(restored.User.DRScaling);
        }
    }
}

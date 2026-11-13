using System;
using System.Collections.Generic;
using VRageRender;

namespace SentisClientOptimisation
{
    /// <summary>Own only a changed field, never a stale whole-settings snapshot.</summary>
    internal sealed class ValueLease<T>
    {
        private bool _owned;
        private T _baseline, _written;
        internal T Apply(T current, bool enabled, Func<T, T> transform)
        {
            if (_owned && !EqualityComparer<T>.Default.Equals(current, _written))
                _baseline = current; // An external settings change wins and becomes the new baseline.
            if (!enabled)
            {
                if (!_owned) return current;
                _owned = false;
                return _baseline;
            }
            if (!_owned) { _baseline = current; _owned = true; }
            _written = transform(_baseline);
            return _written;
        }
    }

    internal sealed class RenderTuning
    {
        private readonly Dictionary<string, object> _leases = new Dictionary<string, object>();
        internal bool RenderChanged { get; private set; }
        internal bool DebugChanged { get; private set; }
        private T Tune<T>(string key, T value, bool enabled, Func<T, T> transform, bool debug)
        {
            if (!_leases.TryGetValue(key, out var slot)) _leases[key] = slot = new ValueLease<T>();
            var result = ((ValueLease<T>)slot).Apply(value, enabled, transform);
            if (!EqualityComparer<T>.Default.Equals(value, result))
            {
                if (debug) DebugChanged = true;
                else RenderChanged = true;
            }
            return result;
        }
        internal void Apply(ref MyRenderSettings settings, VRageRender.Messages.MyRenderDebugOverrides debug, OptimisationSettings config, bool boosted)
        {
            RenderChanged = DebugChanged = false;
            settings.EnableShadows = Tune("EnableShadows", settings.EnableShadows, config.DisableShadows, baseline => false, false);
            settings.User.ShadowQuality = Tune("User.ShadowQuality", settings.User.ShadowQuality, config.DisableShadows, baseline => MyShadowsQuality.DISABLED, false);
            settings.FlaresIntensity = Tune("FlaresIntensity", settings.FlaresIntensity, config.DisableFlares, baseline => 0f, false);
            settings.User.GrassDrawDistance = Tune("User.GrassDrawDistance", settings.User.GrassDrawDistance, config.DisableFoliage, baseline => 0f, false);
            settings.User.GrassDensityFactor = Tune("User.GrassDensityFactor", settings.User.GrassDensityFactor, config.DisableFoliage, baseline => 0f, false);
            settings.User.AmbientOcclusionEnabled = Tune("User.AmbientOcclusionEnabled", settings.User.AmbientOcclusionEnabled, config.DisableAmbientOcclusion, baseline => false, false);
            settings.User.AntialiasingMode = Tune("User.AntialiasingMode", settings.User.AntialiasingMode, config.DisableAntialiasing, baseline => MyAntialiasingMode.NONE, false);
            settings.RenderBlocksToEnvProbe = Tune("RenderBlocksToEnvProbe", settings.RenderBlocksToEnvProbe, config.DisableReflections, baseline => false, false);
            settings.User.ParticleQuality = Tune("User.ParticleQuality", settings.User.ParticleQuality, config.LowParticleQuality, baseline => MyRenderQualityEnum.LOW, false);
            settings.User.LightsQuality = Tune("User.LightsQuality", settings.User.LightsQuality, config.LowLightingQuality, baseline => MyRenderQualityEnum.LOW, false);
            settings.User.DistanceFade = Tune("User.DistanceFade", settings.User.DistanceFade, config.ReduceDistance, baseline => System.Math.Min(baseline, boosted ? System.Math.Min(config.DistanceFade, 150) : config.DistanceFade), false);
            if (debug == null) return;
            debug.Shadows = Tune("debug.Shadows", debug.Shadows, config.DisableShadows, baseline => false, true);
            debug.Fog = Tune("debug.Fog", debug.Fog, config.DisableFog, baseline => false, true);
            debug.Flares = Tune("debug.Flares", debug.Flares, config.DisableFlares, baseline => false, true);
            debug.Clouds = Tune("debug.Clouds", debug.Clouds, config.DisableClouds, baseline => false, true);
            debug.Foliage = Tune("debug.Foliage", debug.Foliage, config.DisableFoliage, baseline => false, true);
            debug.SSAO = Tune("debug.SSAO", debug.SSAO, config.DisableAmbientOcclusion, baseline => false, true);
            debug.Bloom = Tune("debug.Bloom", debug.Bloom, config.DisableBloom, baseline => false, true);
            debug.Fxaa = Tune("debug.Fxaa", debug.Fxaa, config.DisableAntialiasing, baseline => false, true);
            debug.GPUParticles = Tune("debug.GPUParticles", debug.GPUParticles, config.DisableGpuParticles, baseline => false, true);
        }
    }
}

using System;
using System.Collections.Generic;

namespace SentisClientOptimisation
{
    internal sealed class AdaptiveLimits
    {
        private double _warmup, _overloaded, _recovered;
        internal bool Active { get; private set; }
        internal void Reset() { _warmup = _overloaded = _recovered = 0; Active = false; }
        internal bool Tick(double seconds, float frameMs, float gpuMs, float cpuMs, int targetFps, bool eligible)
        {
            if (!eligible || seconds <= 0 || seconds > 1 || float.IsNaN(frameMs) || float.IsNaN(gpuMs) || float.IsNaN(cpuMs) ||
                frameMs <= 0 || frameMs > 1000 || gpuMs < 0 || cpuMs < 0)
            {
                Reset();
                return false;
            }
            _warmup += seconds;
            if (_warmup < 5) return false;
            var budget = 1000.0 / Math.Max(20, targetFps);
            var renderMs = Math.Max(gpuMs, cpuMs);
            if (!Active)
            {
                _overloaded = frameMs > budget * 1.15 && renderMs > budget * 1.1 ? _overloaded + seconds : 0;
                if (_overloaded >= 2) { Active = true; _overloaded = _recovered = 0; }
            }
            else
            {
                _recovered = frameMs < budget * 0.9 && renderMs < budget * 0.9 ? _recovered + seconds : 0;
                if (_recovered >= 5) { Active = false; _overloaded = _recovered = 0; }
            }
            return Active;
        }
    }

    internal static class ParticleLimits
    {
        // Exact names verified in the game's particle definitions. Never guess by substring: mod effects pass through.
        private static readonly HashSet<string> Cosmetic = new HashSet<string>(StringComparer.Ordinal)
        {
            "Smoke_DrillDust", "Smoke_DrillDust_MarsSoil", "Smoke_DrillDust_Snow", "Smoke_DrillDust_Sand",
            "Smoke_DrillDust_Soil", "Smoke_DrillDust_Ice", "Smoke_DrillDust_Grass", "Smoke_DrillDust_GrassOld",
            "Smoke_DrillDust_Moon", "Smoke_DrillDust_OrangeAlienGrass", "Smoke_DrillDust_AlienGreenGrass",
            "Smoke_DrillDust_AlienYellowGrass", "Smoke_DrillDust_Metal", "Smoke_HandDrillDust",
            "Smoke_HandDrillDustStones", "Smoke_HandDrillDust_MarsSoil", "Smoke_HandDrillDust_Snow",
            "Smoke_HandDrillDust_Ice", "Smoke_HandDrillDust_Sand", "Smoke_HandDrillDust_MoonSoil",
            "Smoke_HandDrillDust_Grass", "Smoke_HandDrillDust_GrassOld", "Smoke_HandDrillDust_OrangeAlienGrass",
            "Smoke_HandDrillDust_AlienGreenGrass", "Smoke_HandDrillDust_AlienYellowGrass", "Smoke_HandDrillDust_Metal",
            "WheelDust_GrassGreen", "WheelDust_Snow", "WheelDust_Rock", "WheelDust_MoonSoil", "WheelDust_Metal",
            "WheelDust_Sand", "WheelDust_GrassOrange", "WheelDust_GrassYellow", "WheelDust_Dirt", "WheelDust_MarsSoil",
            "ExhaustCarSmoke", "ExhaustCarSmokeSmall", "ExhaustSmoke", "ExhaustSmokeSmall", "ExhaustSmokeWhite", "ExhaustSmokeWhiteSmall"
        };
        internal static bool ShouldSkip(OptimisationSettings config, bool boosted, string name, int active, uint parent, double distanceSquared)
        {
            if (!config.LimitParticles || name == null || !Cosmetic.Contains(name)) return false;
            var limit = boosted ? Math.Min(config.MaxParticles, 40) : config.MaxParticles;
            if (active >= limit) return true;
            var distance = boosted ? Math.Min(config.ParticleDistance, 100) : config.ParticleDistance;
            return parent == uint.MaxValue && !double.IsNaN(distanceSquared) && distanceSquared > (double)distance * distance;
        }
    }
}

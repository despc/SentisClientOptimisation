namespace SentisClientOptimisation
{
    /// <summary>All visual trade-offs are opt-in. Existing freeze fixes remain independent.</summary>
    public sealed class OptimisationSettings
    {
        public bool LimitParticles { get; set; }
        public bool ReduceLod { get; set; }
        public bool ReduceDistance { get; set; }
        public bool DisableShadows { get; set; }
        public bool DisableFog { get; set; }
        public bool DisableFlares { get; set; }
        public bool DisableClouds { get; set; }
        public bool DisableFoliage { get; set; }
        public bool DisableAmbientOcclusion { get; set; }
        public bool DisableBloom { get; set; }
        public bool DisableAntialiasing { get; set; }
        public bool DisableGpuParticles { get; set; }
        public bool DisableReflections { get; set; }
        public bool LowParticleQuality { get; set; }
        public bool LowLightingQuality { get; set; }
        public bool AdaptiveQuality { get; set; }
        public bool ShowOverlay { get; set; }
        public bool WarnIntegratedGpu { get; set; }
        public int TargetFps { get; set; } = 60;
        public int MaxParticles { get; set; } = 120;
        public int ParticleDistance { get; set; } = 200;
        public int LodPercent { get; set; } = 75;
        public int DistanceFade { get; set; } = 450;

        public void Normalize()
        {
            TargetFps = Clamp(TargetFps, 20, 144);
            MaxParticles = Clamp(MaxParticles, 10, 1000);
            ParticleDistance = Clamp(ParticleDistance, 40, 2000);
            LodPercent = Clamp(LodPercent, 25, 100);
            DistanceFade = Clamp(DistanceFade, 120, 2000);
        }

        private static int Clamp(int value, int min, int max) => System.Math.Max(min, System.Math.Min(max, value));
        public OptimisationSettings Clone() => (OptimisationSettings)MemberwiseClone();
    }
}

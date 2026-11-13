using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using HarmonyLib;
using Sandbox;
using Sandbox.Engine.Platform.VideoMode;
using Sandbox.Engine.Utils;
using Sandbox.Game.World;
using Sandbox.Graphics;
using Sandbox.Graphics.GUI;
using Sandbox.ModAPI;
using VRage.Game;
using VRageMath;
using VRageRender;

namespace SentisClientOptimisation
{
    internal static class OptimisationRuntime
    {
        private static RenderTuning _tuning = new RenderTuning();
        private static ValueLease<float> _lod = new ValueLease<float>();
        private static MyNewLoddingSettings _lodSettings;
        private static readonly AdaptiveLimits Adaptive = new AdaptiveLimits();
        private static readonly Stopwatch Clock = Stopwatch.StartNew();
        private static double _lastUpdate;
        private static MySession _session;
        private static bool _suspended, _failed, _warned;
        private static volatile bool _boosted;
        private static volatile bool _particlesEnabled;
        private static readonly OptimisationSettings Off = new OptimisationSettings();

        internal static void Initialize(Harmony harmony)
        {
            var installed = new List<(MethodBase Target, MethodInfo Patch)>();
            void Patch(MethodBase target, string patchName, bool prefix)
            {
                if (target == null) throw new MissingMethodException(patchName);
                var method = AccessTools.Method(typeof(OptimisationRuntime), patchName);
                var patch = new HarmonyMethod(method);
                if (prefix) harmony.Patch(target, prefix: patch);
                else harmony.Patch(target, postfix: patch);
                installed.Add((target, method));
            }
            try
            {
                // One factory covers string and numeric public overloads without double counting.
                Patch(AccessTools.Method(typeof(MyParticlesManager), "CreateParticleEffect", new[]
                {
                    typeof(string), typeof(MatrixD).MakeByRefType(), typeof(Vector3D).MakeByRefType(), typeof(uint), typeof(bool), typeof(int)
                }), nameof(ParticlePrefix), true);
                Patch(AccessTools.Method(typeof(MyGuiSandbox), "Draw", Type.EmptyTypes), nameof(DrawOverlay), false);
                foreach (var name in new[] { "SpaceEngineers.Game.GUI.MyGuiScreenOptionsGraphics, SpaceEngineers.Game", "Sandbox.Game.Gui.MyGuiScreenOptionsDisplay, Sandbox.Game" })
                {
                    var type = Type.GetType(name, true);
                    foreach (var constructor in type.GetConstructors(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
                        Patch(constructor, nameof(BeforeNativeOptions), true);
                }
            }
            catch
            {
                foreach (var item in installed) harmony.Unpatch(item.Target, item.Patch);
                throw;
            }
        }

        private static bool Ready => MySandboxGame.Static != null && MyRenderProxy.IsInstantiated;
        private static bool NativeOptionsOpen => MyScreenManager.Screens.Any(s =>
            s.GetType().FullName == "SpaceEngineers.Game.GUI.MyGuiScreenOptionsGraphics" || s.GetType().FullName == "Sandbox.Game.Gui.MyGuiScreenOptionsDisplay");

        private static void BeforeNativeOptions()
        {
            Restore(); // Native constructors capture their original settings: restore BEFORE they read them.
            _suspended = true;
            _particlesEnabled = false;
        }

        internal static void SettingsChanged()
        {
            _failed = false;
            Adaptive.Reset();
            _boosted = false;
            _lastUpdate = 0;
            Update();
        }

        internal static void Update()
        {
            if (_failed || !Ready) return;
            try
            {
                if (!ReferenceEquals(_session, MySession.Static))
                {
                    Restore();
                    _session = MySession.Static;
                    _tuning = new RenderTuning();
                    _lod = new ValueLease<float>();
                    _lodSettings = null;
                    Adaptive.Reset();
                    _warned = false;
                    _boosted = false;
                    _lastUpdate = 0;
                }
                if (NativeOptionsOpen)
                {
                    if (!_suspended) BeforeNativeOptions();
                    return;
                }
                _suspended = false;
                var config = OptimisationPreferences.Current;
                var inWorld = _session != null && _session.Ready;
                _particlesEnabled = inWorld && config.LimitParticles;
                var now = Clock.Elapsed.TotalSeconds;
                var elapsed = now - _lastUpdate;
                if (_lastUpdate != 0 && elapsed < 0.25) return;
                _lastUpdate = now;
                _boosted = Adaptive.Tick(elapsed, MyFpsManager.FrameTimeAvg, MyRenderProxy.GPUTimeSmooth, MyRenderProxy.CPUTimeSmooth, config.TargetFps,
                    config.AdaptiveQuality && inWorld && !MySandboxGame.IsPaused);
                Apply(inWorld ? config : Off);
                if (inWorld && config.WarnIntegratedGpu && !_warned) CheckAdapter();
            }
            catch (Exception e)
            {
                _failed = true;
                _particlesEnabled = false;
                Plugin.Log("Visual optimisations suspended: " + e);
                try { Restore(); } catch (Exception restore) { Plugin.Log("Visual restore: " + restore); }
            }
        }

        private static void Apply(OptimisationSettings config)
        {
            var settings = MyRenderProxy.Settings;
            _tuning.Apply(ref settings, MyRenderProxy.DebugOverrides, config, _boosted);
            if (_tuning.RenderChanged)
            {
                MyRenderProxy.Settings = settings;
                MyRenderProxy.SwitchRenderSettings(settings);
            }
            if (_tuning.DebugChanged) MyRenderProxy.UpdateDebugOverrides();
            ApplyLod(config.ReduceLod, config.LodPercent);
        }

        private static void ApplyLod(bool enabled, int percent)
        {
            var current = MySector.Lodding?.CurrentSettings;
            if (!ReferenceEquals(current, _lodSettings))
            {
                ReleaseLod();
                _lodSettings = current;
                _lod = new ValueLease<float>();
            }
            if (current == null) return;
            var previous = current.Global.ObjectDistanceMult;
            var factor = _boosted ? Math.Min(percent, 40) / 100f : percent / 100f;
            var next = _lod.Apply(previous, enabled, baseline => baseline * factor);
            if (next.Equals(previous)) return;
            current.Global.ObjectDistanceMult = next;
            MyRenderProxy.UpdateNewLoddingSettings(current);
        }

        private static void ReleaseLod()
        {
            if (_lodSettings == null) return;
            var previous = _lodSettings.Global.ObjectDistanceMult;
            var restored = _lod.Apply(previous, false, value => value);
            _lodSettings.Global.ObjectDistanceMult = restored;
            if (!restored.Equals(previous) && Ready && ReferenceEquals(_lodSettings, MySector.Lodding?.CurrentSettings))
                MyRenderProxy.UpdateNewLoddingSettings(_lodSettings);
        }

        private static void Restore()
        {
            _boosted = false;
            _particlesEnabled = false;
            Adaptive.Reset();
            if (Ready) Apply(Off);
            ReleaseLod();
        }

        internal static void Dispose()
        {
            Restore();
            _session = null;
            _lodSettings = null;
            _tuning = new RenderTuning();
            _lod = new ValueLease<float>();
        }

        private static bool ParticlePrefix(string name, ref Vector3D worldPosition, uint parentID, ref MyParticleEffect __result)
        {
            if (!_particlesEnabled || _suspended) return true;
            var distance = MySector.MainCamera == null ? double.NaN : Vector3D.DistanceSquared(worldPosition, MySector.MainCamera.Position);
            if (!ParticleLimits.ShouldSkip(OptimisationPreferences.Current, _boosted, name, MyParticlesManager.InstanceCount, parentID, distance)) return true;
            __result = null;
            return false;
        }

        private static void DrawOverlay()
        {
            if (!OptimisationPreferences.Current.ShowOverlay || MySession.Static == null || !MySession.Static.Ready) return;
            var text = OptimisationText.Get("Fps") + ": " + MyFpsManager.GetFps() +
                " | " + OptimisationText.Get("Gpu") + ": " + MyRenderProxy.GPUTimeSmooth.ToString("0.0") + " " + OptimisationText.Get("Milliseconds") +
                " | " + OptimisationText.Get("Cpu") + ": " + MyRenderProxy.CPUTimeSmooth.ToString("0.0") + " " + OptimisationText.Get("Milliseconds") +
                " | " + OptimisationText.Get("Particles") + ": " + MyParticlesManager.InstanceCount +
                (_boosted ? " | " + OptimisationText.Get("AdaptiveActive") : "");
            MyGuiManager.DrawString("Debug", text, new Vector2(0.012f, 0.012f), 0.58f, Color.LightGreen);
        }

        private static void CheckAdapter()
        {
            var adapters = MyVideoSettingsManager.Adapters;
            var index = MyVideoSettingsManager.CurrentDeviceSettings.AdapterOrdinal;
            if (adapters == null || index < 0 || index >= adapters.Length) return;
            _warned = true;
            bool Integrated(string name) => !string.IsNullOrEmpty(name) &&
                ((name.IndexOf("Intel", StringComparison.OrdinalIgnoreCase) >= 0 && name.IndexOf("Arc", StringComparison.OrdinalIgnoreCase) < 0) ||
                 name.IndexOf("Radeon(TM) Graphics", StringComparison.OrdinalIgnoreCase) >= 0 || name.IndexOf("Radeon Graphics", StringComparison.OrdinalIgnoreCase) >= 0);
            bool Discrete(string name) => !string.IsNullOrEmpty(name) &&
                (name.IndexOf("NVIDIA", StringComparison.OrdinalIgnoreCase) >= 0 || name.IndexOf("Radeon RX", StringComparison.OrdinalIgnoreCase) >= 0 || name.IndexOf("Intel(R) Arc", StringComparison.OrdinalIgnoreCase) >= 0);
            if (Integrated(adapters[index].Name) && adapters.Where((a, i) => i != index).Any(a => Discrete(a.Name)))
                MyAPIGateway.Utilities?.ShowNotification(OptimisationText.Get("IntegratedGpuWarning"), 7000, "Red");
        }
    }
}

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using Sandbox;
using Sandbox.Game.World;
using Sandbox.Graphics.GUI;
using VRage.Game;
using VRage.Plugins;
using VRageMath;
using VRageRender;
using VRageRender.Messages;

namespace OptimisationSmoke
{
    /// <summary>Opt-in test-only client plugin. Run ONLY with an isolated -appdata and copied empty world.</summary>
    public sealed class Plugin : IPlugin
    {
        private string _root;
        private Assembly _plugin;
        private int _step;
        private double _next;
        private bool _finished;
        private readonly Stopwatch _clock = Stopwatch.StartNew();
        private MyGuiScreenBase _options, _screen;
        private MyRenderSettings _baseline;
        private MyRenderDebugOverrides _debug;
        private float _lod;
        private readonly List<MyParticleEffect> _effects = new List<MyParticleEffect>();
        private const BindingFlags Static = BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;

        public void Init(object gameInstance)
        {
            _root = Environment.GetEnvironmentVariable("SENTIS_OPT_SMOKE_ROOT");
            if (string.IsNullOrEmpty(_root)) { _finished = true; return; }
            Directory.CreateDirectory(_root);
            File.WriteAllText(Path.Combine(_root, "report.txt"), "Live client optimisation lifecycle\n");
        }
        private Type Type(string name) => _plugin.GetType("SentisClientOptimisation." + name, true);
        private object Current => Type("OptimisationPreferences").GetProperty("Current", Static).GetValue(null);
        private bool Preference(string key) => (bool)Current.GetType().GetProperty(key).GetValue(Current);
        private void Call(string type, string method) => Type(type).GetMethod(method, Static).Invoke(null, null);
        private void Check(bool condition, string label)
        {
            File.AppendAllText(Path.Combine(_root, "report.txt"), (condition ? "PASS " : "FAIL ") + label + "\n");
            if (!condition) throw new InvalidOperationException(label);
        }
        private void Note(string text) => File.AppendAllText(Path.Combine(_root, "report.txt"), text + "\n");
        private void Language(string name)
        {
            var property = MySandboxGame.Config.GetType().GetProperty("Language");
            property.SetValue(MySandboxGame.Config, Enum.Parse(property.PropertyType, name));
        }
        private void OpenOptions()
        {
            _options = (MyGuiScreenBase)Activator.CreateInstance(System.Type.GetType("SpaceEngineers.Game.GUI.MyGuiScreenOptionsSpace, SpaceEngineers.Game", true), true);
            MyGuiSandbox.AddScreen(_options);
        }
        private void OpenScreen()
        {
            _options.Controls.OfType<MyGuiControlButton>().Single(b => b.Name == "SentisOptimisation").PressButton();
            var pending = typeof(MyScreenManager).GetField("m_screensToAdd", BindingFlags.Static | BindingFlags.NonPublic)?.GetValue(null) as IEnumerable<MyGuiScreenBase>;
            _screen = MyScreenManager.Screens.Concat(pending ?? Enumerable.Empty<MyGuiScreenBase>()).Last(s => s.GetType().Name == "OptimisationScreen");
        }
        private static IEnumerable<MyGuiControlBase> Flatten(MyGuiControlBase control)
        {
            yield return control;
            if (control is MyGuiControlParent parent)
                foreach (var child in parent.Controls.SelectMany(Flatten)) yield return child;
            if (control is MyGuiControlScrollablePanel scroll)
                foreach (var child in Flatten(scroll.ScrolledControl)) yield return child;
        }
        private IEnumerable<MyGuiControlBase> Content => _screen.Controls.SelectMany(Flatten);
        private void Press(string name) => _screen.Controls.OfType<MyGuiControlButton>().Single(b => b.Name == name).PressButton();
        private void Configure(bool enabled)
        {
            foreach (var box in Content.OfType<MyGuiControlCheckbox>()) box.IsChecked = enabled;
            foreach (var slider in Content.OfType<MyGuiControlSlider>())
            {
                if (slider.Name == "MaxParticles") slider.Value = 10;
                if (slider.Name == "ParticleDistance") slider.Value = 40;
                if (slider.Name == "LodPercent") slider.Value = 50;
            }
        }
        private void Screenshot(string name) => MyRenderProxy.TakeScreenshot(Vector2.One, Path.Combine(_root, name + ".png"), false, false, false);
        private void WaitNext(double delay = 2) { _step++; _next = _clock.Elapsed.TotalSeconds + delay; }

        public void Update()
        {
            if (_finished || _clock.Elapsed.TotalSeconds < _next) return;
            try
            {
                _plugin = AppDomain.CurrentDomain.GetAssemblies().FirstOrDefault(a => a.GetName().Name == "SentisClientOptimisation");
                if (_plugin == null) return;
                switch (_step)
                {
                    case 0:
                        if (!MyScreenManager.Screens.Any(s => s.GetType().Name.Contains("MainMenu"))) return;
                        Check(Path.GetFullPath(VRage.FileSystem.MyFileSystem.UserDataPath).StartsWith(Path.GetFullPath(_root), StringComparison.OrdinalIgnoreCase), "isolated game user-data path");
                        Language("Russian"); OpenOptions(); WaitNext(); break;
                    case 1:
                        var size = _options.Size;
                        _options.RecreateControls(false);
                        Check(_options.Controls.OfType<MyGuiControlButton>().Count(b => b.Name == "SentisOptimisation") == 1, "one optimisation menu entry after recreation");
                        Check(_options.Size == size, "menu size does not grow on recreation");
                        var button = _options.Controls.OfType<MyGuiControlButton>().Single(b => b.Name == "SentisOptimisation");
                        Check(button.Text == "Оптимизация", "Russian native menu label");
                        Note("menu size=" + _options.Size + "; button=" + button.Position + "; button size=" + button.Size);
                        Screenshot("01-options-ru"); OpenScreen(); WaitNext(); break;
                    case 2:
                        Check(Content.OfType<MyGuiControlCheckbox>().Count() == 18, "all eighteen checkboxes created");
                        Check(Content.OfType<MyGuiControlSlider>().Count() == 5, "all five sliders created");
                        Screenshot("02-settings-ru");
                        Configure(true); Press("Cancel"); WaitNext(); break;
                    case 3:
                        Check(!Preference("DisableFog"), "Cancel leaves preferences unchanged");
                        OpenScreen(); Configure(true); Press("Apply"); WaitNext(); break;
                    case 4:
                        Check(Preference("DisableFog"), "Apply stores checked options");
                        Check(File.Exists(Path.Combine(VRage.FileSystem.MyFileSystem.UserDataPath, "Storage", "SentisClientOptimisation_Config.xml")), "preferences persisted in isolated profile");
                        Language("English"); _options.RecreateControls(false);
                        Check(_options.Controls.OfType<MyGuiControlButton>().Single(b => b.Name == "SentisOptimisation").Text == "Optimisation", "English native menu label");
                        OpenScreen(); WaitNext(); break;
                    case 5:
                        Screenshot("03-settings-en");
                        Press("Defaults"); Check(Preference("DisableFog"), "Reset does not apply before confirmation");
                        Press("Apply"); WaitNext(); break;
                    case 6:
                        Check(!Preference("DisableFog"), "Reset and Apply restore default preferences");
                        _options.CloseScreenNow();
                        MySessionLoader.LoadSingleplayerSession(Path.Combine(_root, "world"));
                        WaitNext(5); break;
                    case 7:
                        if (MySession.Static == null || !MySession.Static.Ready || MySector.MainCamera == null) return;
                        _baseline = MyRenderProxy.Settings; _debug = MyRenderProxy.DebugOverrides.Clone(); _lod = MySector.Lodding.CurrentSettings.Global.ObjectDistanceMult;
                        OpenOptions(); OpenScreen(); Configure(true); Press("Apply"); WaitNext(); break;
                    case 8:
                        Check(!MyRenderProxy.DebugOverrides.Fog && !MyRenderProxy.DebugOverrides.Bloom && !MyRenderProxy.DebugOverrides.GPUParticles, "live fog/bloom/GPU switches applied");
                        Check(!MyRenderProxy.Settings.EnableShadows && MyRenderProxy.Settings.FlaresIntensity == 0, "live shadows and flares disabled");
                        Check(MyRenderProxy.Settings.User.DRScaling == _baseline.User.DRScaling && MyRenderProxy.DebugOverrides.EnableDRS == _debug.EnableDRS, "live dynamic resolution preserved");
                        Check(Math.Abs(MySector.Lodding.CurrentSettings.Global.ObjectDistanceMult - _lod * 0.5f) < 0.001f, "live LOD limit applied without compounding");
                        var position = MySector.MainCamera.Position;
                        var matrix = MatrixD.CreateTranslation(position);
                        bool rejected = false;
                        for (var i = 0; i < 20; i++)
                        {
                            if (MyParticlesManager.TryCreateParticleEffect("Smoke_DrillDust", ref matrix, ref position, uint.MaxValue, out var effect)) _effects.Add(effect);
                            else rejected = true;
                        }
                        Check(rejected, "live cosmetic particle spawning is limited");
                        Check(MyParticlesManager.TryCreateParticleEffect("Smoke_Missile", ref matrix, ref position, uint.MaxValue, out var cue), "live missile cue survives full cosmetic limit");
                        if (cue != null) _effects.Add(cue);
                        foreach (var effect in _effects) MyParticlesManager.RemoveParticleEffect(effect);
                        _effects.Clear();
                        Screenshot("04-live-enabled");
                        _options.CloseScreenNow();
                        var graphics = (MyGuiScreenBase)Activator.CreateInstance(System.Type.GetType("SpaceEngineers.Game.GUI.MyGuiScreenOptionsGraphics, SpaceEngineers.Game", true), true);
                        Check(MyRenderProxy.DebugOverrides.Fog == _debug.Fog && MyRenderProxy.Settings.FlaresIntensity == _baseline.FlaresIntensity, "native graphics constructor sees restored settings");
                        MyGuiSandbox.AddScreen(graphics); graphics.CloseScreenNow();
                        WaitNext(); break;
                    case 9:
                        Check(!MyRenderProxy.DebugOverrides.Fog, "overrides resume after native graphics screen closes");
                        OpenOptions(); OpenScreen(); Press("Defaults"); Press("Apply"); WaitNext(); break;
                    case 10:
                        Check(MyRenderProxy.DebugOverrides.Fog == _debug.Fog && MyRenderProxy.DebugOverrides.Bloom == _debug.Bloom && MyRenderProxy.DebugOverrides.GPUParticles == _debug.GPUParticles, "live unchecked debug switches restore original values");
                        Check(MyRenderProxy.Settings.EnableShadows == _baseline.EnableShadows && MyRenderProxy.Settings.FlaresIntensity == _baseline.FlaresIntensity, "live unchecked render switches restore original values");
                        Check(Math.Abs(MySector.Lodding.CurrentSettings.Global.ObjectDistanceMult - _lod) < 0.001f, "live unchecked LOD restores original value");
                        _options.CloseScreenNow();
                        Screenshot("05-live-restored");
                        MySessionLoader.UnloadAndExitToMenu(); WaitNext(5); break;
                    case 11:
                        if (MySession.Static != null || !MyScreenManager.Screens.Any(s => s.GetType().Name.Contains("MainMenu"))) return;
                        MySessionLoader.LoadSingleplayerSession(Path.Combine(_root, "world")); WaitNext(5); break;
                    case 12:
                        if (MySession.Static == null || !MySession.Static.Ready) return;
                        Check(!Preference("DisableFog") && !Preference("ReduceLod"), "settings remain disabled after world reload");
                        Check(MyRenderProxy.DebugOverrides.Fog == _debug.Fog && MyRenderProxy.DebugOverrides.GPUParticles == _debug.GPUParticles, "world reload has no sticky effect overrides");
                        Note("COMPLETE"); File.WriteAllText(Path.Combine(_root, "done.txt"), "PASS");
                        _finished = true;
                        MySessionLoader.ExitGame(); break;
                }
            }
            catch (Exception e)
            {
                Note("ERROR " + e); File.WriteAllText(Path.Combine(_root, "done.txt"), "FAIL"); _finished = true;
            }
        }
        public void Dispose() { }
    }
}

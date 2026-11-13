using System;
using System.Reflection;
using System.Text;
using Sandbox;
using Sandbox.Graphics.GUI;
using VRage.Utils;
using VRageMath;

namespace SentisClientOptimisation
{
    internal sealed class OptimisationScreen : MyGuiScreenBase
    {
        internal static readonly string[] SettingKeys =
        {
            "LimitParticles", "MaxParticles", "ParticleDistance", "DisableGpuParticles", "LowParticleQuality",
            "DisableShadows", "DisableFog", "DisableFlares", "DisableClouds", "DisableFoliage", "DisableAmbientOcclusion",
            "DisableBloom", "DisableAntialiasing", "DisableReflections", "LowLightingQuality", "ReduceLod", "LodPercent",
            "ReduceDistance", "DistanceFade", "AdaptiveQuality", "TargetFps", "ShowOverlay", "WarnIntegratedGpu"
        };
        private OptimisationSettings _draft;
        private MyGuiControlParent _content;
        private MyGuiControlLabel _status;
        private float _row;

        public OptimisationScreen()
            : base(new Vector2(0.5f, 0.5f), MyGuiConstants.SCREEN_BACKGROUND_COLOR, new Vector2(0.88f, 0.92f),
                backgroundTransition: MySandboxGame.Config.UIBkOpacity, guiTransition: MySandboxGame.Config.UIOpacity)
        {
            _draft = OptimisationPreferences.Current.Clone();
            EnabledBackgroundFade = true;
            m_closeOnEsc = true;
            CloseButtonEnabled = true;
            RecreateControls(true);
        }

        public override string GetFriendlyName() => "SentisOptimisation";

        public override void RecreateControls(bool constructor)
        {
            base.RecreateControls(constructor);
            if (_draft == null) _draft = OptimisationPreferences.Current.Clone();
            AddCaption(OptimisationText.Get("Title"));
            const float rowHeight = 0.052f;
            var height = (SettingKeys.Length + 4) * rowHeight + 0.03f;
            _content = new MyGuiControlParent(size: new Vector2(0.75f, height));
            _row = -height / 2 + 0.03f;
            Section("EffectsSection");
            Toggle("LimitParticles");
            Number("MaxParticles", 10, 1000);
            Number("ParticleDistance", 40, 2000);
            Toggle("LowParticleQuality");
            Toggle("DisableGpuParticles");
            Section("GraphicsSection");
            foreach (var key in new[] { "DisableShadows", "DisableFog", "DisableFlares", "DisableClouds", "DisableFoliage", "DisableAmbientOcclusion", "DisableBloom", "DisableAntialiasing", "DisableReflections", "LowLightingQuality" }) Toggle(key);
            Toggle("ReduceLod");
            Number("LodPercent", 25, 100);
            Toggle("ReduceDistance");
            Number("DistanceFade", 120, 2000);
            Section("AdaptiveSection");
            Toggle("AdaptiveQuality");
            Number("TargetFps", 20, 144);
            Section("DiagnosticsSection");
            Toggle("ShowOverlay");
            Toggle("WarnIntegratedGpu");
            var scroll = new MyGuiControlScrollablePanel(_content)
            {
                Name = "OptimisationSettings", Position = new Vector2(0, -0.005f), Size = new Vector2(0.80f, 0.68f),
                ScrollbarVEnabled = true, ScrollbarHEnabled = false
            };
            Controls.Add(scroll);
            _status = new MyGuiControlLabel(position: new Vector2(0, 0.35f), text: "", textScale: 0.65f,
                originAlign: MyGuiDrawAlignEnum.HORISONTAL_CENTER_AND_VERTICAL_CENTER);
            Controls.Add(_status);
            Button("Defaults", -0.25f, () => { _draft = new OptimisationSettings(); RecreateControls(false); });
            Button("Apply", 0, Apply);
            Button("Cancel", 0.25f, () => CloseScreen());
        }

        private void Section(string key)
        {
            _content.Controls.Add(new MyGuiControlLabel(new Vector2(-0.36f, _row), text: OptimisationText.Get(key), textScale: 0.78f, font: "Blue"));
            _row += 0.052f;
        }

        private void Toggle(string key)
        {
            var property = typeof(OptimisationSettings).GetProperty(key);
            Label(key, 0.63f);
            var checkbox = new MyGuiControlCheckbox(new Vector2(0.32f, _row), toolTip: OptimisationText.Get(key + "Tip"), isChecked: (bool)property.GetValue(_draft));
            checkbox.Name = key;
            checkbox.IsCheckedChanged += c => property.SetValue(_draft, c.IsChecked);
            _content.Controls.Add(checkbox);
            _row += 0.052f;
        }

        private void Number(string key, int minimum, int maximum)
        {
            var property = typeof(OptimisationSettings).GetProperty(key);
            Label(key, 0.42f);
            var slider = new MyGuiControlSlider(new Vector2(0.18f, _row), minimum, maximum, width: 0.28f,
                defaultValue: (int)property.GetValue(_draft), labelText: "{0}", labelDecimalPlaces: 0,
                labelScale: 0.65f, labelSpaceWidth: 0.045f, toolTip: OptimisationText.Get(key + "Tip"), intValue: true, showLabel: true);
            slider.Name = key;
            slider.Value = (int)property.GetValue(_draft);
            slider.ValueChanged += s => property.SetValue(_draft, (int)Math.Round(s.Value));
            _content.Controls.Add(slider);
            _row += 0.052f;
        }

        private void Label(string key, float maxWidth)
        {
            var label = new MyGuiControlLabel(new Vector2(-0.36f, _row), text: OptimisationText.Get(key), textScale: 0.67f);
            label.SetMaxWidth(maxWidth);
            label.SetToolTip(OptimisationText.Get(key + "Tip"));
            _content.Controls.Add(label);
        }

        private void Button(string key, float x, Action action)
        {
            var button = new MyGuiControlButton(new Vector2(x, 0.40f), text: new StringBuilder(OptimisationText.Get(key)), onButtonClick: _ => action());
            button.Name = key;
            Controls.Add(button);
        }

        private void Apply()
        {
            if (!OptimisationPreferences.Replace(_draft))
            {
                _status.Text = OptimisationText.Get("SaveError");
                return;
            }
            OptimisationRuntime.SettingsChanged();
            CloseScreen();
        }
    }
}

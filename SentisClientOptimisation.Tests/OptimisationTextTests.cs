using System;
using System.Linq;
using System.Reflection;
using Xunit;

namespace SentisClientOptimisation.Tests
{
    public sealed class OptimisationTextTests
    {
        [Fact]
        public void Every_setting_has_a_label_and_tooltip_in_both_languages()
        {
            var type = typeof(Plugin).Assembly.GetType("SentisClientOptimisation.OptimisationText");
            Assert.NotNull(type);
            var get = type.GetMethod("Get", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic, null, new[] { typeof(string), typeof(bool) }, null);
            foreach (var key in typeof(OptimisationSettings).GetProperties().SelectMany(p => new[] { p.Name, p.Name + "Tip" })
                .Concat(new[] { "Title", "Apply", "Cancel", "Defaults", "EffectsSection", "GraphicsSection", "DiagnosticsSection", "AdaptiveSection", "SaveError", "IntegratedGpuWarning", "Fps", "Gpu", "Cpu", "Particles", "AdaptiveActive" }))
            {
                foreach (var russian in new[] { false, true })
                {
                    var text = (string)get.Invoke(null, new object[] { key, russian });
                    Assert.False(string.IsNullOrWhiteSpace(text), key);
                    Assert.DoesNotContain("[", text);
                    if (russian && key != "Fps" && key != "Gpu" && key != "Cpu") Assert.NotEqual(key, text);
                }
            }
            Assert.Equal("Оптимизация", get.Invoke(null, new object[] { "Title", true }));
            Assert.Equal("Optimisation", get.Invoke(null, new object[] { "Title", false }));
        }
    }
}

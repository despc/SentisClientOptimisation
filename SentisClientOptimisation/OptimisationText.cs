using System;
using System.Collections.Generic;
using Sandbox;

namespace SentisClientOptimisation
{
    internal static class OptimisationText
    {
        private static readonly Dictionary<string, string[]> Strings = new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            { "Title", new[] { "Optimisation", "Оптимизация" } },
            { "Apply", new[] { "Apply", "Применить" } },
            { "Cancel", new[] { "Cancel", "Отмена" } },
            { "Defaults", new[] { "Reset", "Сбросить" } },
            { "SaveError", new[] { "Could not save settings. Changes were not applied.", "Не удалось сохранить настройки. Изменения не применены." } },
            { "EffectsSection", new[] { "Effects", "Эффекты" } },
            { "GraphicsSection", new[] { "Graphics", "Графика" } },
            { "DiagnosticsSection", new[] { "Diagnostics", "Диагностика" } },
            { "AdaptiveSection", new[] { "Adaptive quality", "Адаптивное качество" } },
            { "LimitParticles", new[] { "Limit cosmetic particles", "Ограничивать декоративные частицы" } },
            { "LimitParticlesTip", new[] { "Limit known dust, smoke and spark effects by count and range. Unknown and modded effects are kept. Existing effects finish normally.", "Ограничивать известные эффекты пыли, дыма и искр по числу и дальности. Неизвестные эффекты и эффекты модов сохраняются. Уже созданные эффекты завершаются штатно." } },
            { "ReduceLod", new[] { "Reduce detail distance (LOD)", "Снизить дальность детализации (LOD)" } },
            { "ReduceLodTip", new[] { "Switch to simpler models sooner. Geometry may visibly change at shorter distances.", "Раньше переключаться на упрощённые модели. Детализация объектов может меняться на меньшей дистанции." } },
            { "ReduceDistance", new[] { "Reduce small-object draw distance", "Снизить дальность мелких объектов" } },
            { "ReduceDistanceTip", new[] { "Reduce distance fading for small objects. Distant small details may disappear.", "Снизить дистанцию отрисовки мелких объектов. Удалённые мелкие детали могут исчезать." } },
            { "DisableShadows", new[] { "Disable shadows", "Отключить тени" } },
            { "DisableShadowsTip", new[] { "Disable shadow rendering. Unchecking restores the previous shadow settings.", "Отключить отрисовку теней. Снятие галочки возвращает прежние настройки теней." } },
            { "DisableFog", new[] { "Disable fog", "Отключить туман" } },
            { "DisableFogTip", new[] { "Remove atmospheric fog. Changes the appearance of planets.", "Убрать атмосферный туман. Меняет внешний вид планет." } },
            { "DisableFlares", new[] { "Disable lens flares", "Отключить блики" } },
            { "DisableFlaresTip", new[] { "Hide lens flares from the sun and lights.", "Скрыть блики солнца и источников света." } },
            { "DisableClouds", new[] { "Disable clouds", "Отключить облака" } },
            { "DisableCloudsTip", new[] { "Hide planetary cloud layers.", "Скрыть слои облаков планет." } },
            { "DisableFoliage", new[] { "Disable grass", "Отключить траву" } },
            { "DisableFoliageTip", new[] { "Disable decorative foliage and grass. Does not remove physical trees.", "Отключить декоративную растительность и траву. Не удаляет физические деревья." } },
            { "DisableAmbientOcclusion", new[] { "Disable ambient occlusion (SSAO)", "Отключить затенение (SSAO)" } },
            { "DisableAmbientOcclusionTip", new[] { "Remove contact shading around objects. May flatten the image.", "Убрать контактное затенение вокруг объектов. Картинка может выглядеть более плоской." } },
            { "DisableBloom", new[] { "Disable bloom", "Отключить свечение (Bloom)" } },
            { "DisableBloomTip", new[] { "Remove glow around bright surfaces. Tone mapping remains unchanged.", "Убрать ореолы ярких поверхностей. Тональная коррекция не меняется." } },
            { "DisableAntialiasing", new[] { "Disable antialiasing", "Отключить сглаживание" } },
            { "DisableAntialiasingTip", new[] { "Disable antialiasing and FXAA. Edges may look jagged.", "Отключить сглаживание и FXAA. На границах объектов могут появиться ступеньки." } },
            { "DisableGpuParticles", new[] { "Disable all GPU particles", "Отключить все GPU-частицы" } },
            { "DisableGpuParticlesTip", new[] { "Aggressive: hides GPU smoke, sparks and other particle cues, including mod effects.", "Агрессивный режим: скрывает дым, искры и другие GPU-эффекты, включая эффекты модов и визуальные подсказки." } },
            { "DisableReflections", new[] { "Simplify environment reflections", "Упростить отражения окружения" } },
            { "DisableReflectionsTip", new[] { "Do not render blocks into environment probes. Reflections become less accurate.", "Не отрисовывать блоки в зонды окружения. Отражения станут менее точными." } },
            { "LowParticleQuality", new[] { "Low particle quality", "Низкое качество частиц" } },
            { "LowParticleQualityTip", new[] { "Use the renderer's low particle-quality setting.", "Использовать низкое качество частиц в рендере." } },
            { "LowLightingQuality", new[] { "Low lighting quality", "Низкое качество освещения" } },
            { "LowLightingQualityTip", new[] { "Use the renderer's low lighting-quality setting.", "Использовать низкое качество освещения в рендере." } },
            { "AdaptiveQuality", new[] { "Adaptive effect and LOD limits", "Адаптивные лимиты эффектов и LOD" } },
            { "AdaptiveQualityTip", new[] { "Under sustained rendering load, tighten only the enabled particle, LOD and distance limits. Restore them after recovery. Does not enable other switches.", "При длительной нагрузке рендера усиливать только включённые лимиты частиц, LOD и дальности. После восстановления возвращать их. Не включает другие галочки." } },
            { "ShowOverlay", new[] { "Show performance overlay", "Показывать оверлей производительности" } },
            { "ShowOverlayTip", new[] { "Show rendered FPS, GPU/CPU render time and active effect count in a world.", "Показывать FPS отрисовки, время GPU/CPU рендера и число активных эффектов в мире." } },
            { "WarnIntegratedGpu", new[] { "Warn about integrated graphics", "Предупреждать о встроенной графике" } },
            { "WarnIntegratedGpuTip", new[] { "Warn once per session if the selected adapter appears integrated while a discrete adapter is available. Detection is heuristic.", "Предупреждать раз за сессию, если выбрана предположительно встроенная графика при наличии дискретной. Определение приблизительное." } },
            { "TargetFps", new[] { "Target FPS", "Целевой FPS" } },
            { "TargetFpsTip", new[] { "Render-time budget for adaptive limits. Not an FPS cap.", "Бюджет времени рендера для адаптивных лимитов. Не ограничитель FPS." } },
            { "MaxParticles", new[] { "Particle count limit", "Лимит числа эффектов" } },
            { "MaxParticlesTip", new[] { "Above this total active-effect count, new known cosmetic particles are skipped. Other effects are kept.", "При превышении этого общего числа активных эффектов новые известные декоративные частицы пропускаются. Другие эффекты сохраняются." } },
            { "ParticleDistance", new[] { "Particle distance (m)", "Дальность частиц (м)" } },
            { "ParticleDistanceTip", new[] { "Maximum range of new known cosmetic effects without a parent. Parented effects are not distance-culled.", "Предельная дальность новых известных декоративных эффектов без родителя. Эффекты с родителем по дальности не отсекаются." } },
            { "LodPercent", new[] { "LOD distance (%)", "Дальность LOD (%)" } },
            { "LodPercentTip", new[] { "Percentage of the normal detail distance. Lower values select simpler models sooner.", "Процент обычной дальности детализации. Меньшие значения раньше включают упрощённые модели." } },
            { "DistanceFade", new[] { "Small-object distance (m)", "Дальность мелких объектов (м)" } },
            { "DistanceFadeTip", new[] { "Maximum distance-fade setting while its switch is enabled. Never increases the original setting.", "Максимальная настройка дальности при включённой галочке. Не увеличивает исходную дальность." } },
            { "Fps", new[] { "FPS", "FPS" } },
            { "Gpu", new[] { "GPU", "GPU" } },
            { "Cpu", new[] { "CPU", "CPU" } },
            { "Particles", new[] { "Effects", "Эффекты" } },
            { "AdaptiveActive", new[] { "adaptive", "адаптация" } },
            { "Milliseconds", new[] { "ms", "мс" } },
            { "IntegratedGpuWarning", new[] { "Optimisation: integrated graphics may be selected while a discrete GPU is available. Check Windows graphics preferences.", "Оптимизация: возможно, выбрана встроенная графика при наличии дискретной. Проверьте параметры графики Windows." } },
        };
        internal static string Get(string key) => Get(key, IsRussian);
        internal static string Get(string key, bool russian) => Strings.TryGetValue(key, out var value) ? value[russian ? 1 : 0] : "[" + key + "]";
        internal static bool IsRussian
        {
            get
            {
                try { return string.Equals(MySandboxGame.Config?.Language.ToString(), "Russian", StringComparison.OrdinalIgnoreCase); }
                catch (Exception) { return false; }
            }
        }
    }
}

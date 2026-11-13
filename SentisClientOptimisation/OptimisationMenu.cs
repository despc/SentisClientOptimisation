using System;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;
using HarmonyLib;
using Sandbox.Graphics.GUI;
using VRageMath;

namespace SentisClientOptimisation
{
    internal static class OptimisationMenu
    {
        private const string ButtonName = "SentisOptimisation";
        private const float AdditionalRowHeight = 0.06f;
        private static readonly ConditionalWeakTable<MyGuiScreenBase, object> Expanded = new ConditionalWeakTable<MyGuiScreenBase, object>();
        internal static void Patch(Harmony harmony)
        {
            var options = Type.GetType("SpaceEngineers.Game.GUI.MyGuiScreenOptionsSpace, SpaceEngineers.Game", true);
            var target = AccessTools.DeclaredMethod(options, "RecreateControls", new[] { typeof(bool) });
            if (target == null) throw new MissingMethodException(options.FullName, "RecreateControls");
            harmony.Patch(target, prefix: new HarmonyMethod(typeof(OptimisationMenu), nameof(BeforeRecreate)),
                postfix: new HarmonyMethod(typeof(OptimisationMenu), nameof(AfterRecreate)));
        }

        private static void BeforeRecreate(MyGuiScreenBase __instance)
        {
            if (!__instance.Size.HasValue || Expanded.TryGetValue(__instance, out _)) return;
            // Give the extra native-sized row room; do not squeeze buttons or overlay the footer.
            __instance.Size += new Vector2(0, AdditionalRowHeight);
            Expanded.Add(__instance, new object());
        }

        private static void AfterRecreate(MyGuiScreenBase __instance)
        {
            if (__instance.Controls.OfType<MyGuiControlButton>().Any(b => b.Name == ButtonName)) return;
            var last = __instance.Controls.OfType<MyGuiControlButton>().FirstOrDefault(b => b.Name == "Credits");
            if (last == null) throw new InvalidOperationException("Native options layout has no Credits anchor.");
            var button = new MyGuiControlButton(last.Position + new Vector2(0, AdditionalRowHeight),
                text: new StringBuilder(OptimisationText.Get("Title")), onButtonClick: _ => Open());
            button.Name = ButtonName;
            __instance.Controls.Add(button);
            var group = AccessTools.Field(__instance.GetType(), "m_elementGroup")?.GetValue(__instance) as MyGuiControlElementGroup;
            group?.Add(button);
        }

        internal static void Refresh()
        {
            foreach (var screen in MyScreenManager.Screens)
            {
                if (screen.GetType().FullName != "SpaceEngineers.Game.GUI.MyGuiScreenOptionsSpace") continue;
                var button = screen.Controls.OfType<MyGuiControlButton>().FirstOrDefault(b => b.Name == ButtonName);
                var title = OptimisationText.Get("Title");
                if (button != null && button.Text != title) button.Text = title;
            }
        }

        internal static void Open()
        {
            if (MyScreenManager.Screens.Any(s => s is OptimisationScreen)) return;
            MyGuiSandbox.AddScreen(new OptimisationScreen());
        }
    }
}

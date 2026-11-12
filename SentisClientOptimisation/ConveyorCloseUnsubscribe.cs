using System;
using System.Collections.Generic;
using System.Reflection;
using HarmonyLib;
using Sandbox.Game.Entities.Cube;
using Sandbox.Game.EntityComponents;
using Sandbox.Game.GameSystems.Conveyors;

namespace SentisClientOptimisation
{
    /// <summary>
    /// A big grid's conveyor blocks no longer leave its conveyor system's power one by one when the grid closes.
    ///
    /// Every conveyor endpoint of a grid subscribes to the grid's conveyor system's <c>ResourceSink.IsPoweredChanged</c>;
    /// when the grid closes each endpoint unsubscribes (<c>MyMultilineConveyorEndpoint.Unregister</c>), and every
    /// unsubscribe makes the list of all of them anew: 0.3 s of a grid's deleting in a trace of a player's client
    /// (11.11.2026). Now, while a grid closes (<c>MyCubeGridSystems.BeforeGridClose</c> to
    /// <c>AfterGridClose</c>), the endpoints do not unsubscribe one by one; their handlers are taken out of the event
    /// at once when it is closed (or at the next frame, whatever happens between).
    /// </summary>
    internal static class ConveyorCloseUnsubscribe
    {
        public static long Grids, Endpoints;

        private static AccessTools.FieldRef<MyMultilineConveyorEndpoint, MyResourceSinkComponent> _sink;
        private static FieldInfo _isPoweredChanged;

        /// <summary>The sinks of the conveyor systems of the closing grids, with the endpoints that did not unsubscribe.</summary>
        private static readonly Dictionary<MyResourceSinkComponent, HashSet<object>> Closing = new Dictionary<MyResourceSinkComponent, HashSet<object>>();

        public static void Patch(Harmony harmony)
        {
            _sink = AccessTools.FieldRefAccess<MyMultilineConveyorEndpoint, MyResourceSinkComponent>("m_conveyorSystemSink");
            _isPoweredChanged = AccessTools.Field(typeof(MyResourceSinkComponent), "IsPoweredChanged")
                                ?? throw new MissingFieldException("MyResourceSinkComponent", "IsPoweredChanged");
            var unregister = AccessTools.Method(typeof(MyMultilineConveyorEndpoint), nameof(MyMultilineConveyorEndpoint.Unregister))
                             ?? throw new MissingMethodException("MyMultilineConveyorEndpoint", "Unregister");
            var before = AccessTools.Method(typeof(MyCubeGridSystems), nameof(MyCubeGridSystems.BeforeGridClose))
                         ?? throw new MissingMethodException("MyCubeGridSystems", "BeforeGridClose");
            var after = AccessTools.Method(typeof(MyCubeGridSystems), nameof(MyCubeGridSystems.AfterGridClose))
                        ?? throw new MissingMethodException("MyCubeGridSystems", "AfterGridClose");
            harmony.Patch(before, postfix: new HarmonyMethod(typeof(ConveyorCloseUnsubscribe), nameof(BeforePostfix)));
            harmony.Patch(unregister, prefix: new HarmonyMethod(typeof(ConveyorCloseUnsubscribe), nameof(UnregisterPrefix)));
            harmony.Patch(after, finalizer: new HarmonyMethod(typeof(ConveyorCloseUnsubscribe), nameof(AfterFinalizer)));
        }

        private static void BeforePostfix(MyCubeGridSystems __instance)
        {
            try
            {
                var sink = __instance.ConveyorSystem?.ResourceSink;
                if (sink == null || Closing.ContainsKey(sink)) return;
                Closing[sink] = Subscribers.NewSet();
                Grids++;
            }
            catch (Exception e)
            {
                Plugin.Log("conveyors of a closing grid: " + e);
            }
        }

        /// <summary>An endpoint of a closing grid: not unsubscribed now (<see cref="Flush"/> does it).</summary>
        private static void UnregisterPrefix(MyMultilineConveyorEndpoint __instance)
        {
            if (Closing.Count == 0) return;
            var sink = _sink(__instance);
            if (sink == null || !Closing.TryGetValue(sink, out var skipped)) return;
            skipped.Add(__instance);
            _sink(__instance) = null;
            Endpoints++;
        }

        private static Exception AfterFinalizer(MyCubeGridSystems __instance, Exception __exception)
        {
            try
            {
                var sink = __instance.ConveyorSystem?.ResourceSink;
                if (sink != null && Closing.TryGetValue(sink, out var skipped))
                {
                    Closing.Remove(sink);
                    Subscribers.RemoveTargets(sink, _isPoweredChanged, skipped);
                }
            }
            catch (Exception e)
            {
                Plugin.Log("conveyors of a closed grid: " + e);
            }
            return __exception;
        }

        /// <summary>What a grid's closing left (an exception between its start and its end): every frame.</summary>
        public static void Flush()
        {
            if (Closing.Count == 0) return;
            foreach (var pair in Closing)
            {
                try { Subscribers.RemoveTargets(pair.Key, _isPoweredChanged, pair.Value); }
                catch (Exception e) { Plugin.Log("conveyors left of a closed grid: " + e); }
            }
            Closing.Clear();
        }
    }
}

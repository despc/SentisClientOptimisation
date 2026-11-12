using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using HarmonyLib;
using Sandbox.Game.GameSystems;
using Sandbox.Game.GameSystems.Conveyors;

namespace SentisClientOptimisation
{
    /// <summary>
    /// A grid's thrusters find the conveyor groups they draw fuel from once a set of mutually reachable conveyor
    /// endpoints, not once an endpoint and a group.
    ///
    /// The thrust component of a grid (<c>MyEntityThrustComponent</c>) keeps its thrusters in groups joined by
    /// conveyors both ways (hydrogen reaches them). When blocks come (a grid streamed, built, docked) it takes them in
    /// its next update (<c>UpdateConveyorSystemChanges</c>): every thruster registered tests every group by two walks of
    /// the conveyor graph (<c>Register</c> → <c>FindConnectedGroups</c>: <c>Reachable</c> each way), every changed
    /// endpoint makes two walks (<c>FindMutuallyReachableGroups</c>), and so does every group when all are merged
    /// (<c>TryMergeAllGroups</c>) - walks of the whole graph, under one lock for all the grids of the world
    /// (<c>MyGridConveyorSystem.Pathfinding</c>), so the parallel update waits on it. 13.5 s of a two minutes' trace of a
    /// player's client, 3.8 s of one frame's update (11.11.2026).
    ///
    /// The groups an endpoint joins are those whose first endpoint is mutually reachable with it - in its strongly
    /// connected set, the same for every endpoint of the set (a walk yields its start, so the set is reflexive and the
    /// same from any of its members). Now, within one <c>UpdateConveyorSystemChanges</c> (the conveyor graph changes
    /// only on the game thread, not during the parallel update), the set is walked once (forward and inverted, as the
    /// game's <c>FindMutuallyReachableGroups</c> does) and kept for all its endpoints; the groups are picked from it as
    /// the game picks them. Outside of it everything is the game's.
    /// </summary>
    internal static class ThrustConveyorScc
    {
        public static long Walked, Reused;

        [ThreadStatic] private static SccCache<IMyConveyorEndpoint> _batch;
        [ThreadStatic] private static int _depth;

        private static Action<MyEntityThrustComponent, IMyConveyorEndpoint, List<MyEntityThrustComponent.MyConveyorConnectedGroup>, List<int>> _mutual;
        private static Action<IMyConveyorEndpointBlock, List<MyEntityThrustComponent.MyConveyorConnectedGroup>, List<int>> _connected;

        public static void Patch(Harmony harmony)
        {
            var type = typeof(MyEntityThrustComponent);
            var mutual = AccessTools.Method(type, "FindMutuallyReachableGroups") ?? throw new MissingMethodException(type.Name, "FindMutuallyReachableGroups");
            var connected = AccessTools.Method(type, "FindConnectedGroups", new[] { typeof(IMyConveyorEndpointBlock), typeof(List<MyEntityThrustComponent.MyConveyorConnectedGroup>), typeof(List<int>) })
                            ?? throw new MissingMethodException(type.Name, "FindConnectedGroups(IMyConveyorEndpointBlock)");
            var update = AccessTools.Method(type, "UpdateConveyorSystemChanges") ?? throw new MissingMethodException(type.Name, "UpdateConveyorSystemChanges");
            var mergeAll = AccessTools.Method(type, "TryMergeAllGroups") ?? throw new MissingMethodException(type.Name, "TryMergeAllGroups");
            var register = AccessTools.Method(type, nameof(MyEntityThrustComponent.Register)) ?? throw new MissingMethodException(type.Name, "Register");
            _mutual = (Action<MyEntityThrustComponent, IMyConveyorEndpoint, List<MyEntityThrustComponent.MyConveyorConnectedGroup>, List<int>>)
                Delegate.CreateDelegate(typeof(Action<MyEntityThrustComponent, IMyConveyorEndpoint, List<MyEntityThrustComponent.MyConveyorConnectedGroup>, List<int>>), mutual);
            _connected = (Action<IMyConveyorEndpointBlock, List<MyEntityThrustComponent.MyConveyorConnectedGroup>, List<int>>)
                Delegate.CreateDelegate(typeof(Action<IMyConveyorEndpointBlock, List<MyEntityThrustComponent.MyConveyorConnectedGroup>, List<int>>), connected);

            var self = typeof(ThrustConveyorScc);
            harmony.Patch(update, prefix: new HarmonyMethod(self, nameof(Begin)), finalizer: new HarmonyMethod(self, nameof(End)),
                transpiler: new HarmonyMethod(self, nameof(MutualTranspiler)));
            harmony.Patch(mergeAll, transpiler: new HarmonyMethod(self, nameof(MutualTranspiler)));
            harmony.Patch(register, transpiler: new HarmonyMethod(self, nameof(ConnectedTranspiler)));
        }

        private static IEnumerable<CodeInstruction> Replace(IEnumerable<CodeInstruction> instructions, MethodInfo target, string with, int atLeast)
        {
            var code = instructions.ToList();
            var replaced = 0;
            foreach (var instruction in code)
            {
                if ((instruction.opcode == OpCodes.Call || instruction.opcode == OpCodes.Callvirt) && instruction.operand is MethodInfo method && method == target)
                {
                    instruction.opcode = OpCodes.Call;
                    instruction.operand = AccessTools.Method(typeof(ThrustConveyorScc), with);
                    replaced++;
                }
            }
            if (replaced < atLeast) throw new InvalidOperationException($"{target.Name}: {replaced} calls, this fix knows {atLeast}");
            return code;
        }

        private static IEnumerable<CodeInstruction> MutualTranspiler(IEnumerable<CodeInstruction> instructions) =>
            Replace(instructions, AccessTools.Method(typeof(MyEntityThrustComponent), "FindMutuallyReachableGroups"), nameof(Mutual), 1);

        private static IEnumerable<CodeInstruction> ConnectedTranspiler(IEnumerable<CodeInstruction> instructions) =>
            Replace(instructions, AccessTools.Method(typeof(MyEntityThrustComponent), "FindConnectedGroups",
                new[] { typeof(IMyConveyorEndpointBlock), typeof(List<MyEntityThrustComponent.MyConveyorConnectedGroup>), typeof(List<int>) }), nameof(Connected), 1);

        private static void Begin()
        {
            if (_depth++ == 0) (_batch ?? (_batch = new SccCache<IMyConveyorEndpoint>(Forward, Backward))).Clear();
        }

        private static Exception End(Exception __exception)
        {
            if (--_depth <= 0)
            {
                _depth = 0;
                _batch?.Clear();
            }
            return __exception;
        }

        private static void Forward(IMyConveyorEndpoint from, List<IMyConveyorEndpoint> into) => MyGridConveyorSystem.FindReachable(from, into);
        private static void Backward(IMyConveyorEndpoint from, List<IMyConveyorEndpoint> into) => MyGridConveyorSystem.FindReachableInverted(from, into);

        /// <summary>The game's <c>FindMutuallyReachableGroups</c>: from the set kept within the batch.</summary>
        public static void Mutual(MyEntityThrustComponent self, IMyConveyorEndpoint representative, List<MyEntityThrustComponent.MyConveyorConnectedGroup> groups, List<int> into)
        {
            if (_depth == 0 || representative == null)
            {
                _mutual(self, representative, groups, into);
                return;
            }
            Pick(_batch.Of(representative), groups, into);
        }

        /// <summary>The game's <c>FindConnectedGroups</c> of a thruster: the groups mutually reachable with it, from the set kept within the batch.</summary>
        public static void Connected(IMyConveyorEndpointBlock block, List<MyEntityThrustComponent.MyConveyorConnectedGroup> groups, List<int> into)
        {
            var endpoint = block?.ConveyorEndpoint;
            if (_depth == 0 || endpoint == null)
            {
                _connected(block, groups, into);
                return;
            }
            Pick(_batch.Of(endpoint), groups, into);
        }

        private static void Pick(HashSet<IMyConveyorEndpoint> set, List<MyEntityThrustComponent.MyConveyorConnectedGroup> groups, List<int> into)
        {
            for (var i = 0; i < groups.Count; i++)
            {
                var first = groups[i].FirstEndpoint;
                if (first != null && set.Contains(first)) into.Add(i);
            }
        }
    }

    /// <summary>
    /// The strongly connected sets of a graph that does not change meanwhile: a vertex's set walked once (the vertices
    /// reached from it and those reaching it), kept for every vertex of it.
    /// </summary>
    internal sealed class SccCache<T> where T : class
    {
        private readonly Action<T, List<T>> _forward, _backward;
        private readonly Dictionary<T, HashSet<T>> _of = new Dictionary<T, HashSet<T>>();
        private readonly List<T> _buffer = new List<T>();

        public SccCache(Action<T, List<T>> forward, Action<T, List<T>> backward)
        {
            _forward = forward;
            _backward = backward;
        }

        public void Clear() => _of.Clear();

        public HashSet<T> Of(T vertex)
        {
            if (_of.TryGetValue(vertex, out var set))
            {
                ThrustConveyorScc.Reused++;
                return set;
            }
            ThrustConveyorScc.Walked++;
            _buffer.Clear();
            _forward(vertex, _buffer);
            set = new HashSet<T>(_buffer);
            _buffer.Clear();
            _backward(vertex, _buffer);
            set.IntersectWith(_buffer);
            _buffer.Clear();
            // a walk yields its start; should it not, the vertex still has its own set
            if (!set.Contains(vertex))
            {
                _of[vertex] = set;
                return set;
            }
            foreach (var member in set) _of[member] = set;
            return set;
        }
    }
}

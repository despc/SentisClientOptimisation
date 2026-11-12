using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.CompilerServices;
using HarmonyLib;
using VRage.Game.Components;
using VRage.Game.Components.Interfaces;
using VRage.Game.Entity;
using VRage.ModAPI;

namespace SentisClientOptimisation
{
    /// <summary>
    /// A big grid deleted on the client (gone from the client's range, removed on the server) no longer costs a time
    /// that grows with the square of its blocks.
    ///
    /// A grid's blocks are its children (<see cref="MyHierarchyComponentBase"/>), deleted one by one from the last, and
    /// for each the game did two things that walk all the blocks: took it out of the grid's list of children
    /// (<c>RemoveByJN</c> - <c>List.Remove</c>, a search from the first), and unsubscribed it from the grid's
    /// container's <c>ComponentAdded</c> / <c>ComponentRemoved</c> (each block subscribed to them: an unsubscribe makes
    /// the whole list of subscribers anew). 1.0 s of a 1.6 s frame in a trace of a player's client (11.11.2026).
    ///
    /// Now: a child that is the last of the list is taken off its end; while a hierarchy of many children deletes them,
    /// they do not unsubscribe one by one, and their subscriptions are taken out of the container's events at once when
    /// the deleting is done. The calls are changed in <c>MyEntity.Delete</c> itself, as the game's small methods may be
    /// inlined into it.
    /// </summary>
    internal static class BulkChildDelete
    {
        /// <summary>Children from which the subscriptions are taken out at once.</summary>
        public const int Many = 32;

        /// <summary>Hierarchies deleted at once, children taken off the end of the list.</summary>
        public static long Bulk, FromEnd;

        private static AccessTools.FieldRef<MyHierarchyComponentBase, List<MyHierarchyComponentBase>> _children;
        private static AccessTools.FieldRef<MyHierarchyComponentBase, HashSet<MyHierarchyComponentBase>> _needingMatrix;
        private static AccessTools.FieldRef<MyHierarchyComponentBase, IMyEntityComponentContainer> _parentContainer;
        private static FieldInfo _added, _removed;

        /// <summary>The containers whose children are being deleted at once, with the children that did not unsubscribe.</summary>
        private static readonly Dictionary<object, HashSet<object>> Deleting = new Dictionary<object, HashSet<object>>();

        public static void Patch(Harmony harmony)
        {
            _children = AccessTools.FieldRefAccess<MyHierarchyComponentBase, List<MyHierarchyComponentBase>>("m_children");
            _needingMatrix = AccessTools.FieldRefAccess<MyHierarchyComponentBase, HashSet<MyHierarchyComponentBase>>("m_childrenNeedingWorldMatrix");
            _parentContainer = AccessTools.FieldRefAccess<MyHierarchyComponentBase, IMyEntityComponentContainer>("m_parentContainer");
            _added = AccessTools.Field(typeof(MyEntityComponentContainer), "ComponentAdded") ?? throw new MissingFieldException("MyEntityComponentContainer", "ComponentAdded");
            _removed = AccessTools.Field(typeof(MyEntityComponentContainer), "ComponentRemoved") ?? throw new MissingFieldException("MyEntityComponentContainer", "ComponentRemoved");
            var delete = AccessTools.Method(typeof(MyEntity), nameof(MyEntity.Delete), Type.EmptyTypes) ?? throw new MissingMethodException("MyEntity", "Delete");
            var leave = AccessTools.Method(typeof(MyHierarchyComponentBase), nameof(MyHierarchyComponentBase.OnBeforeRemovedFromContainer))
                        ?? throw new MissingMethodException("MyHierarchyComponentBase", "OnBeforeRemovedFromContainer");
            harmony.Patch(delete, transpiler: new HarmonyMethod(typeof(BulkChildDelete), nameof(Transpiler)));
            harmony.Patch(leave, prefix: new HarmonyMethod(typeof(BulkChildDelete), nameof(LeavePrefix)));
        }

        /// <summary><c>hierarchy.Delete()</c> and <c>parent.Hierarchy.RemoveByJN(child)</c> in <c>MyEntity.Delete</c> through the methods here.</summary>
        private static IEnumerable<CodeInstruction> Transpiler(IEnumerable<CodeInstruction> instructions)
        {
            var deleteChildren = AccessTools.Method(typeof(MyHierarchyComponentBase), nameof(MyHierarchyComponentBase.Delete));
            var removeByJN = AccessTools.Method(typeof(MyHierarchyComponentBase), nameof(MyHierarchyComponentBase.RemoveByJN));
            int deletes = 0, removes = 0;
            var code = instructions.ToList();
            foreach (var instruction in code)
            {
                if ((instruction.opcode == OpCodes.Call || instruction.opcode == OpCodes.Callvirt) && instruction.operand is MethodInfo method)
                {
                    if (method == deleteChildren)
                    {
                        instruction.opcode = OpCodes.Call;
                        instruction.operand = AccessTools.Method(typeof(BulkChildDelete), nameof(DeleteChildren));
                        deletes++;
                    }
                    else if (method == removeByJN)
                    {
                        instruction.opcode = OpCodes.Call;
                        instruction.operand = AccessTools.Method(typeof(BulkChildDelete), nameof(RemoveChild));
                        removes++;
                    }
                }
            }
            if (deletes != 1 || removes != 1)
                throw new InvalidOperationException($"MyEntity.Delete is not what this fix knows: {deletes} hierarchy deletes, {removes} child removes");
            return code;
        }

        /// <summary>The hierarchy's children deleted as the game does it; with many of them, unsubscribed at once after.</summary>
        public static void DeleteChildren(MyHierarchyComponentBase hierarchy)
        {
            var container = hierarchy.Container;
            if (container == null || _children(hierarchy).Count < Many || Deleting.ContainsKey(container))
            {
                hierarchy.Delete();
                return;
            }
            var skipped = Subscribers.NewSet(_children(hierarchy).Count);
            Deleting[container] = skipped;
            Bulk++;
            try
            {
                hierarchy.Delete();
            }
            finally
            {
                Deleting.Remove(container);
                Subscribers.RemoveTargets(container, _added, skipped);
                Subscribers.RemoveTargets(container, _removed, skipped);
            }
        }

        /// <summary>A child leaving the container of a parent deleting many: not unsubscribed now (<see cref="DeleteChildren"/> does it).</summary>
        private static void LeavePrefix(MyHierarchyComponentBase __instance)
        {
            if (Deleting.Count == 0) return;
            var parent = _parentContainer(__instance);
            if (parent == null || !Deleting.TryGetValue(parent, out var skipped)) return;
            skipped.Add(__instance);
            _parentContainer(__instance) = null;
        }

        /// <summary>The game's <c>RemoveByJN</c>; the last child taken off the end of the list.</summary>
        public static void RemoveChild(MyHierarchyComponentBase parent, MyHierarchyComponentBase child)
        {
            var children = _children(parent);
            var last = children.Count - 1;
            if (last >= 0 && ReferenceEquals(children[last], child))
            {
                children.RemoveAt(last);
                _needingMatrix(parent).Remove(child);
                FromEnd++;
                return;
            }
            parent.RemoveByJN(child);
        }

    }
}

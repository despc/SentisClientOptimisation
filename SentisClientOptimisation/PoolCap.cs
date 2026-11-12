using System;
using System.Collections.Generic;
using System.Reflection;
using HarmonyLib;
using VRage.Collections;

namespace SentisClientOptimisation
{
    /// <summary>
    /// A buffer given back to the game's network pools no longer counts every buffer pooled before it.
    ///
    /// <c>MyConcurrentBucketPool&lt;T&gt;.Return</c> asks its stack of pooled buffers for <c>Count</c> before pushing, to
    /// keep under a maximum; a <c>ConcurrentStack</c>'s <c>Count</c> walks the whole stack. The pools of the received
    /// packets (<c>MyReceiveQueue.m_messagePool</c>) and of the replication's bit streams (<c>BitStream.BufferPool</c>)
    /// have no maximum (<c>int.MaxValue</c>): after a burst of packets thousands are pooled, and each one given back
    /// walks them all - 2.95 s of the game thread in a minute's trace of a player's client, up to 0.45 s in a frame
    /// (11.11.2026). (The method itself is not patched: it is of a generic class, which Pulsar's Harmony cannot patch.)
    ///
    /// Now those pools keep at most <see cref="Cap"/> buffers of a size: a count walks at most that many, and a buffer
    /// over it is freed, as the game frees one over any pool's maximum; when a burst needs more, the pool makes them.
    /// </summary>
    internal static class PoolCap
    {
        /// <summary>Buffers of a size a pool keeps.</summary>
        public const int Cap = 512;

        /// <summary>The pools capped: the declaring type's full name and the static field.</summary>
        public static readonly (string Type, string Field)[] Pools =
        {
            ("Sandbox.Engine.Networking.MyReceiveQueue, Sandbox.Game", "m_messagePool"),
            ("VRage.Library.Collections.BitStream, VRage.Library", "BufferPool"),
        };

        public static readonly List<string> Capped = new List<string>();

        public static void Patch(Harmony harmony)
        {
            var missing = new List<string>();
            foreach (var (typeName, fieldName) in Pools)
            {
                var pool = Type.GetType(typeName, false)?.GetField(fieldName, BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public)?.GetValue(null);
                if (pool == null || !SetCap(pool)) missing.Add(typeName + "." + fieldName);
                else Capped.Add(typeName.Split(',')[0] + "." + fieldName);
            }
            if (missing.Count > 0) throw new MissingFieldException("pools not capped: " + string.Join(", ", missing));
        }

        /// <summary>The pool's maximum made <see cref="Cap"/> if it had none; false if it is not a pool this knows.</summary>
        public static bool SetCap(object pool)
        {
            for (var type = pool.GetType(); type != null; type = type.BaseType)
            {
                if (!type.IsGenericType || type.GetGenericTypeDefinition() != typeof(MyConcurrentBucketPool<>)) continue;
                var max = type.GetField("m_maxPooledInstances", BindingFlags.Instance | BindingFlags.NonPublic);
                if (max == null || max.FieldType != typeof(int)) return false;
                if ((int)max.GetValue(pool) == int.MaxValue) max.SetValue(pool, Cap);
                return true;
            }
            return false;
        }
    }
}

using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;

namespace SentisClientOptimisation
{
    /// <summary>
    /// Many subscribers taken out of an event at once: an event's <c>-=</c> makes the whole list of subscribers anew, so
    /// N of them leaving one by one cost N² - the same list made once without them costs N.
    /// </summary>
    internal static class Subscribers
    {
        /// <summary>The event's backing field of the owner without the handlers whose target is one of those given.</summary>
        public static void RemoveTargets(object owner, FieldInfo field, HashSet<object> targets)
        {
            if (owner == null || targets.Count == 0 || !(field.GetValue(owner) is Delegate subscribers)) return;
            var kept = subscribers.GetInvocationList().Where(d => d.Target == null || !targets.Contains(d.Target)).ToArray();
            field.SetValue(owner, kept.Length == 0 ? null : Delegate.Combine(kept));
        }

        public static HashSet<object> NewSet(int capacity = 0) => new HashSet<object>(capacity, Identity.Instance);

        private sealed class Identity : IEqualityComparer<object>
        {
            public static readonly Identity Instance = new Identity();
            public new bool Equals(object x, object y) => ReferenceEquals(x, y);
            public int GetHashCode(object obj) => RuntimeHelpers.GetHashCode(obj);
        }
    }
}

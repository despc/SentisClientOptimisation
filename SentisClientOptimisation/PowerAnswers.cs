using System.Runtime.CompilerServices;
using Sandbox.Game.EntityComponents;
using VRage;

namespace SentisClientOptimisation
{
    /// <summary>
    /// The power a distributor gave its first reader this frame, kept for the other readers of the frame.
    ///
    /// The conveyor lines (<c>LinePowerOnce</c>) and the grid's sound and upgrade modules (<c>PowerReadOnce</c>) ask
    /// the same question: <c>ResourceStateByType</c> of the distributor's first (the electricity) type, to recompute,
    /// without a grid - the lines directly, the readers through the game's <c>ResourceState</c> getter, which is that
    /// call. One answer a frame serves them all.
    /// </summary>
    internal static class PowerAnswers
    {
        private sealed class Answer
        {
            public ulong Frame = ulong.MaxValue;
            public MyResourceStateEnum State;
        }

        private static readonly ConditionalWeakTable<MyResourceDistributorComponent, Answer> Answers = new ConditionalWeakTable<MyResourceDistributorComponent, Answer>();

        internal static bool Has(MyResourceDistributorComponent distributor, ulong frame, out MyResourceStateEnum state)
        {
            if (Answers.TryGetValue(distributor, out var answer) && answer.Frame == frame)
            {
                state = answer.State;
                return true;
            }
            state = default;
            return false;
        }

        internal static void Keep(MyResourceDistributorComponent distributor, ulong frame, MyResourceStateEnum state)
        {
            var answer = Answers.GetOrCreateValue(distributor);
            answer.Frame = frame;
            answer.State = state;
        }
    }
}

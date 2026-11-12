using System;
using System.Threading;

namespace SentisClientOptimisation
{
    /// <summary>
    /// Work for the .NET thread pool, queued without the TPL's tracing: <c>Task.Run</c> writes an ETW event with its
    /// caller's stack whenever a tracer (a profiler) listens - 3.4 s of the game thread in a profiled trace (11.11.2026).
    /// </summary>
    internal static class Background
    {
        public static void Run(Action work) => ThreadPool.UnsafeQueueUserWorkItem(state => ((Action)state)(), work);
    }
}

using System;
using System.Reflection;
using HarmonyLib;
using Sandbox;
using Sandbox.Game.Entities;
using Sandbox.Game.World;
using VRage.Game;
using VRage.Library.Collections;
using VRage.ObjectBuilders;
using VRage.ObjectBuilders.Private;
using VRage.Serialization;

namespace SentisClientOptimisation
{
    /// <summary>
    /// A big grid streamed to the client is no longer read on the game thread.
    ///
    /// When the server streams a grid to the client (it came into range, the player flew up to a base), the client
    /// reads the grid's whole object builder from the received data (<c>MyCubeGridReplicable.OnLoad</c> →
    /// <c>MySerializer.CreateAndRead</c>) on the game thread, then makes the grid on the entity creation thread
    /// (<c>MyEntities.InitAsync</c>) and tells the replication it is there when it is. The reading took 3.6 s of a
    /// minute's trace of a player's client, 2.3 s of one frame for one grid (11.11.2026).
    ///
    /// Now, for data of <see cref="MinBytes"/> or more, the rest of the stream is copied (a memory copy) and read on a
    /// worker thread; back on the game thread the grid is made as the game makes it. The replication already waits for
    /// the grid (it is made asynchronously in the game too), so it only waits a frame or two more. Should the reading
    /// on the worker fail, it is read again on the game thread, as the game does it. A split grid's message (the first
    /// bit set) and small grids are left to the game.
    /// </summary>
    internal static class GridLoadAsync
    {
        public const int MinBytes = 32 * 1024;

        public static long Offloaded, ReadAgain;

        private static MethodInfo _tryRemove;

        public static void Patch(Harmony harmony)
        {
            var type = typeof(MyCubeGrid).Assembly.GetType("Sandbox.Game.Replication.MyCubeGridReplicable", true);
            var load = AccessTools.Method(type, "OnLoad", new[] { typeof(BitStream), typeof(Action<MyCubeGrid>) })
                       ?? throw new MissingMethodException(type.Name, "OnLoad");
            _tryRemove = AccessTools.Method(type, "TryRemoveExistingEntity", new[] { typeof(long) })
                         ?? throw new MissingMethodException(type.Name, "TryRemoveExistingEntity");
            harmony.Patch(load, prefix: new HarmonyMethod(typeof(GridLoadAsync), nameof(LoadPrefix)));
        }

        /// <summary>
        /// A copy of the stream from its read position on, positioned at the same bit: copied from the byte the position
        /// is in (the stream copies whole bytes).
        /// </summary>
        public static BitStream CopyFromPosition(BitStream stream)
        {
            var bit = stream.BitPosition;
            var firstByte = bit / 8;
            var copy = new BitStream();
            copy.ResetRead(stream.DataPointer + (int)firstByte, stream.BitLength - firstByte * 8, true);
            copy.SetBitPositionRead(bit - firstByte * 8);
            return copy;
        }

        private static bool LoadPrefix(object __instance, BitStream stream, Action<MyCubeGrid> loadingDoneHandler)
        {
            BitStream copy;
            var start = stream.BitPosition;
            try
            {
                if (stream.BitLength - start < MinBytes * 8L) return true;
                if (stream.ReadBool())
                {
                    stream.SetBitPositionRead(start);
                    return true;
                }
                copy = CopyFromPosition(stream);
                // the caller checks the stream's terminator (its last 16 bits) after the load
                stream.SetBitPositionRead(Math.Max(stream.BitPosition, stream.BitLength - 16));
            }
            catch (Exception e)
            {
                Plugin.Log("a streamed grid: " + e);
                stream.SetBitPositionRead(start);
                return true;
            }
            Offloaded++;
            var session = MySession.Static;
            var at = copy.BitPosition;
            Background.Run(() =>
            {
                MyObjectBuilder_EntityBase builder = null;
                var timestamp = 0.0;
                try
                {
                    builder = MySerializer.CreateAndRead<MyObjectBuilder_EntityBase>(copy, MyObjectBuilderSerializerKeen.Dynamic);
                    timestamp = copy.ReadDouble();
                }
                catch (Exception e)
                {
                    Plugin.Log("reading a streamed grid on a worker, read again on the game thread: " + e.Message);
                    builder = null;
                }
                MySandboxGame.Static?.Invoke(() => Finish(__instance, session, copy, at, builder, timestamp, loadingDoneHandler), Plugin.Id + " streamed grid");
            });
            return false;
        }

        /// <summary>The rest of the game's <c>OnLoad</c>, on the game thread.</summary>
        private static void Finish(object replicable, MySession session, BitStream copy, long at, MyObjectBuilder_EntityBase builder, double timestamp,
            Action<MyCubeGrid> loadingDoneHandler)
        {
            try
            {
                if (MySession.Static != session) return;
                if (builder == null)
                {
                    ReadAgain++;
                    copy.SetBitPositionRead(at);
                    builder = MySerializer.CreateAndRead<MyObjectBuilder_EntityBase>(copy, MyObjectBuilderSerializerKeen.Dynamic);
                    timestamp = copy.ReadDouble();
                }
                _tryRemove.Invoke(replicable, new object[] { builder.EntityId });
                var grid = MyEntities.CreateFromObjectBuilderNoinit(builder) as MyCubeGrid;
                var fadeIn = builder.PositionAndOrientation.HasValue && MySector.MainCamera != null &&
                             (builder.PositionAndOrientation.Value.Position - MySector.MainCamera.Position).LengthSquared() > 1000000.0;
                MyEntities.InitAsync(grid, builder, true, _ => loadingDoneHandler(grid), timestamp, fadeIn);
            }
            finally
            {
                copy.Dispose();
            }
        }
    }
}

using System;
using HarmonyLib;
using Sandbox;
using Sandbox.Engine.Voxels;
using Sandbox.Game.Entities;
using Sandbox.Game.World;
using VRage.Game.Voxels;
using VRage.Library.Collections;
using VRage.ObjectBuilders;
using VRage.ObjectBuilders.Private;
using VRage.Serialization;
using VRage.Utils;

namespace SentisClientOptimisation
{
    /// <summary>
    /// A changed asteroid or planet streamed to the client with its voxel data is no longer read on the game thread.
    ///
    /// When the server sends a voxel map with its data (a changed asteroid or planet comes into range), the client
    /// reads the data from the received stream and makes the map's storage of it (<c>MyVoxelReplicable.OnLoad</c> →
    /// <c>MyStorageBase.Load</c>: every changed leaf read and unpacked) on the game thread: 1.8 s of one frame in a
    /// trace of a player's client (11.11.2026).
    ///
    /// Now, for a map sent with its data from a prefab (the game's path that loads a storage of data), the rest of the
    /// stream is copied and read on a worker thread, an asteroid's storage made there (a planet's - its generator, the
    /// height maps the game caches - on the game thread, as the game makes it); back on the game thread the map is made
    /// or given the storage as the game does it (<c>Save</c> set, the replication told). The replication waits for the
    /// map as it does for any. Should the worker fail, it is read again on the game thread as the game does it. Maps
    /// without data (the client's own or its cache) are left to the game.
    /// </summary>
    internal static class VoxelLoadAsync
    {
        public static long Offloaded, ReadAgain;

        private static Action<MyPlanet> _storageUpdated;

        public static void Patch(Harmony harmony)
        {
            var updated = AccessTools.Method(typeof(MyPlanet), "VoxelStorageUpdated", Type.EmptyTypes) ?? throw new MissingMethodException("MyPlanet", "VoxelStorageUpdated");
            _storageUpdated = (Action<MyPlanet>)Delegate.CreateDelegate(typeof(Action<MyPlanet>), updated);
            var type = typeof(MyVoxelBase).Assembly.GetType("Sandbox.Game.Replication.MyVoxelReplicable", true);
            var load = AccessTools.Method(type, "OnLoad", new[] { typeof(BitStream), typeof(Action<MyVoxelBase>) })
                       ?? throw new MissingMethodException(type.Name, "OnLoad");
            harmony.Patch(load, prefix: new HarmonyMethod(typeof(VoxelLoadAsync), nameof(LoadPrefix)));
        }

        private sealed class Read
        {
            public bool IsUserCreated, ContentChanged;
            public MyObjectBuilder_EntityBase Builder;
            public byte[] Data;
            public IMyStorage Storage;
        }

        /// <summary>The game's reading of the stream up to the storage made of the data.</summary>
        private static Read ReadAll(BitStream stream)
        {
            var read = new Read
            {
                IsUserCreated = MySerializer.CreateAndRead<bool>(stream),
            };
            MySerializer.CreateAndRead<bool>(stream);   // from a prefab: checked before
            MySerializer.CreateAndRead<bool>(stream);   // with data: checked before
            read.ContentChanged = MySerializer.CreateAndRead<bool>(stream);
            var data = MySerializer.CreateAndRead<byte[]>(stream);
            read.Builder = MySerializer.CreateAndRead<MyObjectBuilder_EntityBase>(stream, MyObjectBuilderSerializerKeen.Dynamic);
            read.Data = data;
            // a planet's storage (its generator, the height maps the game caches) is made on the game thread, as the game makes it
            if (!(read.Builder is VRage.Game.MyObjectBuilder_Planet)) read.Storage = MyStorageBase.Load(data, out _);
            MyLog.Default.WriteLine("MyVoxelReplicable.OnLoad - isUserCreated:" + read.IsUserCreated + " isFromPrefab:True contentChanged:" + read.ContentChanged + " data?: True");
            return read;
        }

        private static bool LoadPrefix(object __instance, BitStream stream, Action<MyVoxelBase> loadingDoneHandler)
        {
            BitStream copy;
            var start = stream.BitPosition;
            try
            {
                MySerializer.CreateAndRead<bool>(stream);
                var fromPrefab = MySerializer.CreateAndRead<bool>(stream);
                var withData = MySerializer.CreateAndRead<bool>(stream);
                stream.SetBitPositionRead(start);
                if (!fromPrefab || !withData) return true;
                copy = GridLoadAsync.CopyFromPosition(stream);
                // the caller checks the stream's terminator (its last 16 bits) after the load
                stream.SetBitPositionRead(Math.Max(stream.BitPosition, stream.BitLength - 16));
            }
            catch (Exception e)
            {
                Plugin.Log("a streamed voxel map: " + e);
                stream.SetBitPositionRead(start);
                return true;
            }
            Offloaded++;
            var session = MySession.Static;
            var at = copy.BitPosition;
            Background.Run(() =>
            {
                Read read = null;
                try
                {
                    read = ReadAll(copy);
                }
                catch (Exception e)
                {
                    Plugin.Log("reading a streamed voxel map on a worker, read again on the game thread: " + e.Message);
                }
                MySandboxGame.Static?.Invoke(() => Finish(session, copy, at, read, loadingDoneHandler), Plugin.Id + " streamed voxel map");
            });
            return false;
        }

        /// <summary>The rest of the game's <c>OnLoad</c> of a map from a prefab with data, on the game thread.</summary>
        private static void Finish(MySession session, BitStream copy, long at, Read read, Action<MyVoxelBase> loadingDoneHandler)
        {
            try
            {
                if (MySession.Static != session) return;
                if (read == null)
                {
                    ReadAgain++;
                    copy.SetBitPositionRead(at);
                    read = ReadAll(copy);
                }
                if (read.Storage == null) read.Storage = MyStorageBase.Load(read.Data, out _);
                var builder = read.Builder;
                if (MyEntities.TryGetEntityById(builder.EntityId, out MyVoxelBase entity, allowClosed: false))
                {
                    if (entity is MyVoxelMap map) map.Storage = read.Storage;
                    else if (entity is MyPlanet planet)
                    {
                        planet.Storage = read.Storage;
                        _storageUpdated(planet);
                    }
                }
                else
                {
                    entity = (MyVoxelBase)MyEntities.CreateFromObjectBuilderNoinit(builder);
                    if (entity is MyVoxelMap map) map.Init(builder, read.Storage);
                    else if (entity is MyPlanet planet)
                    {
                        planet.Init(builder, read.Storage);
                        _storageUpdated(planet);
                    }
                    if (entity != null) MyEntities.Add(entity);
                }
                if (entity != null) entity.Save = true;
                VoxelCacheSave.Given(entity);
                loadingDoneHandler(entity);
            }
            finally
            {
                copy.Dispose();
            }
        }
    }
}
